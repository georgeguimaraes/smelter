defmodule Smelter.Generator.EctoSchema do
  @moduledoc """
  Generates Ecto.Schema modules from resolved JSON Schemas.

  Produces modules with:
  - `use Ecto.Schema` and `import Ecto.Changeset`
  - `@primary_key false` embedded_schema
  - `embeds_one`/`embeds_many` for nested types
  - `changeset/2` function with cast and validations
  - `new/1` convenience function
  """

  alias Smelter.TypeMapper

  @doc """
  Generates Elixir module code from a resolved schema.

  ## Options

  - `:module` - Full module name
  - `:module_prefix` - Prefix for inferred module names (default: "Smelter.Generated")
  """
  @spec generate(map(), keyword()) :: String.t()
  def generate(schema, opts \\ []) do
    module_name = opts[:module] || infer_module_name(schema, opts)
    module_atom = String.to_atom("Elixir.#{module_name}")

    ast =
      case schema[:_composition] do
        {strategy, variants} when strategy in [:one_of, :any_of] ->
          build_union_module_ast(module_atom, schema, strategy, variants, opts)

        _ ->
          properties = schema["properties"] || %{}
          required = schema["required"] || []
          build_schema_module_ast(module_atom, schema, properties, required, opts)
      end

    ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> post_process()
  end

  # Post-process for heredoc formatting and trailing newline
  defp post_process(code) do
    code
    |> convert_moduledoc_to_heredoc()
    |> ensure_trailing_newline()
  end

  defp ensure_trailing_newline(code) do
    if String.ends_with?(code, "\n"), do: code, else: code <> "\n"
  end

  defp convert_moduledoc_to_heredoc(code) do
    Regex.replace(
      ~r/@moduledoc "((?:[^"\\]|\\.)*)"/,
      code,
      fn _, content ->
        unescaped =
          content
          |> String.replace("\\n", "\n")
          |> String.replace("\\\"", "\"")
          |> String.replace("\\\\", "\\")

        indented =
          unescaped
          |> String.split("\n")
          |> Enum.map_join("\n", fn line ->
            if line == "", do: "", else: "  #{line}"
          end)

        ~s|@moduledoc """\n#{indented}\n  """|
      end
    )
  end

  # Build module for union types
  defp build_union_module_ast(module_atom, schema, strategy, variants, opts) do
    moduledoc = build_moduledoc(schema)

    variant_modules =
      variants
      |> Enum.filter(&Map.has_key?(&1, :_ref_module))
      |> Enum.map(& &1[:_ref_module])

    discriminator = detect_discriminator(variants)
    alias_statements = build_union_alias_statements(variant_modules)
    variants_ast = build_variants_attr(variant_modules)
    {cast_doc, cast_def} = build_union_cast_fn(variant_modules, discriminator, strategy, opts)

    body =
      [moduledoc] ++
        alias_statements ++
        [
          variants_ast,
          quote(do: @doc("Returns the variant modules for this union type.")),
          quote(do: def(variants, do: @variants)),
          cast_doc,
          cast_def
        ]

    {:defmodule, [context: Elixir],
     [
       {:__aliases__, [alias: false], module_parts(module_atom)},
       [do: {:__block__, [], body}]
     ]}
  end

  # Build module for regular schemas with embedded_schema
  defp build_schema_module_ast(module_atom, schema, properties, required, opts) do
    moduledoc = build_moduledoc(schema)
    required_atoms = Enum.map(required, &String.to_atom/1)

    # Process properties into fields, embeds, and enums
    {fields, embeds, enums} = categorize_properties(properties, opts)

    # Build module body
    body =
      [moduledoc] ++
        [quote(do: use(Ecto.Schema))] ++
        [quote(do: import(Ecto.Changeset))] ++
        build_alias_statements(embeds) ++
        build_enum_attrs(enums) ++
        build_field_descriptions_attr(properties) ++
        [quote(do: @primary_key(false))] ++
        [build_embedded_schema_ast(fields, embeds, enums)] ++
        build_changeset_fn(fields, embeds, enums, required_atoms) ++
        [build_new_fn()]

    {:defmodule, [context: Elixir],
     [
       {:__aliases__, [alias: false], module_parts(module_atom)},
       [do: {:__block__, [], body}]
     ]}
  end

  # Categorize properties into regular fields, embeds, and enums
  defp categorize_properties(properties, _opts) do
    properties
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.reduce({[], [], []}, fn {name, prop}, {fields, embeds, enums} ->
      {type, type_opts} = TypeMapper.map_type(prop)
      name_atom = String.to_atom(name)

      case type do
        :ref ->
          module = type_opts[:module]
          cardinality = type_opts[:cardinality] || :one
          embed = %{name: name_atom, module: module, cardinality: cardinality}
          {fields, [embed | embeds], enums}

        :enum ->
          values = type_opts[:values]
          enum = %{name: name_atom, values: values}
          {fields, embeds, [enum | enums]}

        :const ->
          value = type_opts[:value]
          enum = %{name: name_atom, values: [value]}
          {fields, embeds, [enum | enums]}

        _ ->
          ecto_type = map_to_ecto_field_type(type, type_opts)
          field = %{name: name_atom, type: ecto_type}
          {[field | fields], embeds, enums}
      end
    end)
    |> then(fn {fields, embeds, enums} ->
      {Enum.reverse(fields), Enum.reverse(embeds), Enum.reverse(enums)}
    end)
  end

  @ecto_type_mappings %{
    string: :string,
    integer: :integer,
    float: :float,
    boolean: :boolean,
    map: :map,
    utc_datetime: :utc_datetime,
    date: :date,
    time: :time,
    binary_id: :binary_id,
    array_of: {:array, :map},
    embedded: :map,
    union: :map,
    union_ref: :map
  }

  # Map internal type to Ecto field type
  defp map_to_ecto_field_type({:array, inner}, _opts), do: {:array, inner}
  defp map_to_ecto_field_type(type, _opts), do: Map.get(@ecto_type_mappings, type, :map)

  # Build alias statements for embedded modules (sorted alphabetically)
  defp build_alias_statements([]), do: []

  defp build_alias_statements(embeds) do
    embeds
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn module ->
      module_ast = module_to_ast(module)
      quote(do: alias(unquote(module_ast)))
    end)
  end

  # Build alias statements for union variant modules (sorted alphabetically)
  defp build_union_alias_statements([]), do: []

  defp build_union_alias_statements(modules) do
    modules
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn module ->
      module_ast = module_to_ast(module)
      quote(do: alias(unquote(module_ast)))
    end)
  end

  # Build enum module attributes
  defp build_enum_attrs([]), do: []

  defp build_enum_attrs(enums) do
    Enum.flat_map(enums, fn %{name: name, values: values} ->
      values_attr = String.to_atom("#{name}_values")
      atom_values = Enum.map(values, &to_safe_atom/1)

      [
        {:@, [context: Elixir], [{values_attr, [context: Elixir], [atom_values]}]}
      ]
    end)
  end

  # Build @field_descriptions attribute and accessor function
  defp build_field_descriptions_attr(properties) do
    descriptions =
      properties
      |> Enum.map(fn {name, prop} ->
        {String.to_atom(name), prop["description"]}
      end)
      |> Enum.into(%{})

    [
      {:@, [context: Elixir],
       [{:field_descriptions, [context: Elixir], [Macro.escape(descriptions)]}]},
      quote(do: @doc("Returns the description for a field, if available.")),
      quote do
        def field_description(field) when is_atom(field) do
          Map.get(@field_descriptions, field)
        end
      end
    ]
  end

  # Build embedded_schema block
  defp build_embedded_schema_ast(fields, embeds, enums) do
    field_asts =
      Enum.map(fields, fn %{name: name, type: type} ->
        quote(do: field(unquote(name), unquote(type)))
      end)

    enum_asts =
      Enum.map(enums, fn %{name: name} ->
        type_attr = {:@, [], [{String.to_atom("#{name}_values"), [], nil}]}

        quote do
          field(
            unquote(name),
            Ecto.Enum,
            values: unquote(type_attr)
          )
        end
      end)

    embed_asts =
      Enum.map(embeds, fn %{name: name, module: module, cardinality: cardinality} ->
        # Use short module name since we have alias
        short_name = module |> String.split(".") |> List.last() |> String.to_atom()
        short_ast = {:__aliases__, [alias: false], [short_name]}

        case cardinality do
          :one -> quote(do: embeds_one(unquote(name), unquote(short_ast)))
          :many -> quote(do: embeds_many(unquote(name), unquote(short_ast)))
        end
      end)

    all_fields = field_asts ++ enum_asts ++ embed_asts

    schema_body =
      if all_fields == [] do
        nil
      else
        {:__block__, [], all_fields}
      end

    quote do
      embedded_schema do
        unquote(schema_body)
      end
    end
  end

  # Build changeset function
  defp build_changeset_fn(fields, embeds, enums, required_atoms) do
    field_names = Enum.map(fields, & &1.name)
    enum_names = Enum.map(enums, & &1.name)
    all_castable = field_names ++ enum_names

    cast_ast =
      quote do
        struct
        |> cast(params, unquote(all_castable))
      end

    # Add cast_embed calls for each embed
    with_embeds =
      Enum.reduce(embeds, cast_ast, fn %{name: name}, acc ->
        is_required = name in required_atoms

        quote do
          unquote(acc)
          |> cast_embed(unquote(name), required: unquote(is_required))
        end
      end)

    # Add validate_required if there are required fields (excluding embeds)
    required_fields = Enum.filter(required_atoms, fn name -> name in all_castable end)

    final_ast =
      if required_fields == [] do
        with_embeds
      else
        quote do
          unquote(with_embeds)
          |> validate_required(unquote(required_fields))
        end
      end

    [
      quote(do: @doc("Creates a changeset for validating and casting params.")),
      quote do
        def changeset(struct \\ %__MODULE__{}, params) do
          unquote(final_ast)
        end
      end
    ]
  end

  # Build new/1 function
  defp build_new_fn do
    quote do
      @doc "Creates a new changeset from params."
      def new(params \\ %{}), do: changeset(params)
    end
  end

  # Build moduledoc
  defp build_moduledoc(schema) do
    title = schema["title"] || "Schema"
    description = schema["description"]

    source =
      case schema[:_source_path] do
        nil -> ""
        path -> "\n\nGenerated from: #{Path.basename(path)}"
      end

    doc_content =
      if description do
        "#{title}\n\n#{description}#{source}"
      else
        "#{title}#{source}"
      end

    {:@, [context: Elixir], [{:moduledoc, [context: Elixir], [doc_content]}]}
  end

  # Union type helpers

  defp detect_discriminator(variants) do
    inline_discriminators =
      variants
      |> Enum.map(fn variant ->
        case variant do
          %{"properties" => %{"type" => %{"const" => value}}} -> {:type, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      inline_discriminators != [] and length(inline_discriminators) == length(variants) ->
        {:discriminated, :type, Enum.map(inline_discriminators, fn {:type, v} -> v end)}

      Enum.all?(variants, &Map.has_key?(&1, :_ref_module)) ->
        inferred = infer_discriminators_from_refs(variants)
        if inferred, do: {:discriminated, :type, inferred}, else: :none

      true ->
        :none
    end
  end

  defp infer_discriminators_from_refs(variants) when length(variants) < 2, do: nil

  defp infer_discriminators_from_refs(variants) do
    basenames =
      Enum.map(variants, fn v ->
        v[:_ref_module] |> String.split(".") |> List.last()
      end)

    common_prefix = find_common_prefix(basenames)

    if String.length(common_prefix) >= 3 do
      infer_discriminator_values(basenames, common_prefix)
    else
      nil
    end
  end

  defp infer_discriminator_values(basenames, common_prefix) do
    values =
      Enum.map(basenames, fn basename ->
        suffix = String.replace_prefix(basename, common_prefix, "")
        if suffix == "", do: nil, else: String.downcase(suffix)
      end)

    if Enum.all?(values, & &1) and length(Enum.uniq(values)) == length(values) do
      values
    else
      nil
    end
  end

  defp find_common_prefix([]), do: ""
  defp find_common_prefix([single]), do: single

  defp find_common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn str, prefix ->
      common_prefix_of_two(prefix, str)
    end)
  end

  defp common_prefix_of_two(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    a_chars
    |> Enum.zip(b_chars)
    |> Enum.take_while(fn {c1, c2} -> c1 == c2 end)
    |> Enum.map_join(fn {c, _} -> c end)
  end

  defp build_variants_attr(variant_modules) do
    module_asts =
      Enum.map(variant_modules, fn mod ->
        parts = mod |> String.split(".") |> Enum.map(&String.to_atom/1)
        {:__aliases__, [alias: false], parts}
      end)

    {:@, [context: Elixir], [{:variants, [context: Elixir], [module_asts]}]}
  end

  defp build_union_cast_fn(variant_modules, discriminator, _strategy, _opts) do
    doc = quote(do: @doc("Casts params to one of the variant types."))

    def_ast =
      case discriminator do
        {:discriminated, field, _values} ->
          build_discriminated_cast(variant_modules, field)

        :none ->
          build_sequential_cast(variant_modules)
      end

    {doc, def_ast}
  end

  defp build_discriminated_cast(variant_modules, field) do
    field_string = Atom.to_string(field)

    clauses =
      Enum.map(variant_modules, fn mod ->
        discriminator_value = infer_discriminator_value(mod)
        # Use short alias name instead of fully qualified
        mod_ast = module_to_short_ast(mod)

        quote do
          %{unquote(field_string) => unquote(discriminator_value)} ->
            unquote(mod_ast).new(params)
        end
      end)

    fallback =
      quote do
        _ -> {:error, :unknown_variant}
      end

    all_clauses = Enum.flat_map(clauses, & &1) ++ fallback

    quote do
      def cast(params) when is_map(params) do
        case params do
          unquote(all_clauses)
        end
      end
    end
  end

  defp infer_discriminator_value(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/^Message/, "")
    |> String.downcase()
  end

  defp build_sequential_cast(variant_modules) do
    # Use short alias names instead of fully qualified
    module_asts = Enum.map(variant_modules, &module_to_short_ast/1)

    quote do
      def cast(params) when is_map(params) do
        Enum.find_value(unquote(module_asts), {:error, :no_matching_variant}, fn mod ->
          case mod.new(params) do
            %Ecto.Changeset{valid?: true} = changeset -> {:ok, changeset}
            _ -> nil
          end
        end)
      end
    end
  end

  # Helpers

  defp module_parts(module_atom) do
    module_atom
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp module_to_ast(module_string) when is_binary(module_string) do
    parts = module_string |> String.split(".") |> Enum.map(&String.to_atom/1)
    {:__aliases__, [alias: false], parts}
  end

  # Convert "Foo.Bar.Baz" to just {:__aliases__, [], [:Baz]} for use with aliases
  defp module_to_short_ast(module_string) when is_binary(module_string) do
    last_part = module_string |> String.split(".") |> List.last() |> String.to_atom()
    {:__aliases__, [alias: false], [last_part]}
  end

  defp to_safe_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_safe_atom(value), do: value

  defp infer_module_name(schema, opts) do
    prefix = opts[:module_prefix] || "Smelter.Generated"

    name =
      cond do
        schema[:_source_path] ->
          schema[:_source_path]
          |> Path.basename(".json")
          |> String.replace(~r/[._]/, " ")
          |> String.split()
          |> Enum.map_join(&String.capitalize/1)

        schema["title"] ->
          schema["title"]
          |> String.replace(~r/[^a-zA-Z0-9\s]/, "")
          |> String.split()
          |> Enum.map_join(&String.capitalize/1)

        true ->
          "Schema"
      end

    "#{prefix}.#{name}"
  end
end
