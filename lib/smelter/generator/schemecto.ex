defmodule Smelter.Generator.Schemecto do
  @moduledoc """
  Generates Schemecto-compatible Elixir modules from resolved JSON Schemas.

  Uses Elixir AST for code generation, then converts to string via Macro.to_string/1.

  Produces modules with:
  - `@fields` module attribute with field definitions
  - `fields/0` function returning field definitions
  - `new/1` function creating changesets with validation
  - Enum type attributes for string enums
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

    # Check for union types (oneOf/anyOf at root level)
    ast =
      case schema[:_composition] do
        {strategy, variants} when strategy in [:one_of, :any_of] ->
          build_union_module_ast(module_atom, schema, strategy, variants, opts)

        _ ->
          # Regular schema with properties
          properties = schema["properties"] || %{}
          required = schema["required"] || []
          {enum_attrs, fields} = process_properties(properties)
          required_atoms = Enum.map(required, &String.to_atom/1)
          build_module_ast(module_atom, schema, enum_attrs, fields, required_atoms)
      end

    # Convert to string and format
    ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> post_process()
  end

  # Post-process the generated code for better formatting
  # Only needed for heredoc conversion - parens are fixed at AST level
  defp post_process(code) do
    # Convert escaped moduledoc strings to heredocs for readability
    convert_moduledoc_to_heredoc(code)
  end

  # Convert @moduledoc "string with \n" to @moduledoc heredoc
  defp convert_moduledoc_to_heredoc(code) do
    # Match @moduledoc followed by a double-quoted string (potentially with escaped chars)
    Regex.replace(
      ~r/@moduledoc "((?:[^"\\]|\\.)*)"/,
      code,
      fn _, content ->
        # Unescape the string
        unescaped =
          content
          |> String.replace("\\n", "\n")
          |> String.replace("\\\"", "\"")
          |> String.replace("\\\\", "\\")

        # Indent each line properly
        indented =
          unescaped
          |> String.split("\n")
          |> Enum.join("\n  ")

        ~s|@moduledoc """\n  #{indented}\n  """|
      end
    )
  end

  # Build module AST for union types (oneOf/anyOf)
  defp build_union_module_ast(module_atom, schema, strategy, variants, opts) do
    moduledoc = build_moduledoc(schema)

    # Extract variant modules from refs
    variant_modules =
      variants
      |> Enum.filter(&Map.has_key?(&1, :_ref_module))
      |> Enum.map(& &1[:_ref_module])

    # Detect discriminator field if present
    discriminator = detect_discriminator(variants)

    # Build variants attribute
    variants_ast = build_variants_attr(variant_modules, opts)

    # Build cast function that tries each variant
    {cast_doc, cast_def} = build_union_cast_fn(variant_modules, discriminator, strategy, opts)

    body =
      [
        moduledoc,
        quote(do: import(Ecto.Changeset)),
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

  # Detect if variants use a discriminator field (const on a common field)
  defp detect_discriminator(variants) do
    # First try: check if variants have inline properties with discriminator
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
      # All variants have inline discriminators
      length(inline_discriminators) == length(variants) and length(variants) > 0 ->
        {:discriminated, :type, Enum.map(inline_discriminators, fn {:type, v} -> v end)}

      # All variants are refs - try to infer discriminator from module names
      # This is a heuristic for common patterns like Message{Error,Warning,Info}
      Enum.all?(variants, &Map.has_key?(&1, :_ref_module)) ->
        inferred = infer_discriminators_from_refs(variants)

        if inferred do
          {:discriminated, :type, inferred}
        else
          :none
        end

      true ->
        :none
    end
  end

  # Try to infer discriminator values from ref module names
  # Works for patterns like MessageError -> "error", MessageWarning -> "warning"
  defp infer_discriminators_from_refs(variants) do
    # Need at least 2 variants for discriminator to make sense
    if length(variants) < 2 do
      nil
    else
      infer_discriminators_from_refs_impl(variants)
    end
  end

  defp infer_discriminators_from_refs_impl(variants) do
    basenames =
      Enum.map(variants, fn v ->
        v[:_ref_module] |> String.split(".") |> List.last()
      end)

    # Find common prefix among all basenames
    common_prefix = find_common_prefix(basenames)

    # Only use discriminator if we found a meaningful common prefix
    # (at least 3 chars to avoid false positives)
    if String.length(common_prefix) >= 3 do
      values =
        Enum.map(basenames, fn basename ->
          suffix = String.replace_prefix(basename, common_prefix, "")

          if suffix == "" do
            # No suffix means this is the base type, can't discriminate
            nil
          else
            String.downcase(suffix)
          end
        end)

      # Only valid if all values are present and unique
      if Enum.all?(values, & &1) and length(Enum.uniq(values)) == length(values) do
        values
      else
        nil
      end
    else
      nil
    end
  end

  # Find the longest common prefix among strings
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
    |> Enum.map(fn {c, _} -> c end)
    |> Enum.join()
  end

  # Build @variants module attribute
  defp build_variants_attr(variant_modules, _opts) do
    module_asts =
      Enum.map(variant_modules, fn mod ->
        parts = mod |> String.split(".") |> Enum.map(&String.to_atom/1)
        {:__aliases__, [alias: false], parts}
      end)

    {:@, [context: Elixir], [{:variants, [context: Elixir], [module_asts]}]}
  end

  # Build cast function for union types
  defp build_union_cast_fn(variant_modules, discriminator, _strategy, _opts) do
    doc = quote(do: @doc("Casts params to one of the variant types."))

    def_ast =
      case discriminator do
        {:discriminated, field, _values} ->
          # Generate pattern-matching cast based on discriminator
          build_discriminated_cast(variant_modules, field)

        :none ->
          # Try each variant in order
          build_sequential_cast(variant_modules)
      end

    {doc, def_ast}
  end

  # Build cast function that pattern matches on discriminator
  defp build_discriminated_cast(variant_modules, field) do
    field_string = Atom.to_string(field)

    clauses =
      Enum.map(variant_modules, fn mod ->
        # Extract the const value for this variant by inferring from module name
        # e.g., "Bazaar.Schemas.Generated.Shopping.Types.MessageError" -> "error"
        discriminator_value = infer_discriminator_value(mod)
        mod_ast = module_to_ast(mod)

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

  # Infer discriminator value from module name
  # e.g., "...MessageError" -> "error", "...MessageWarning" -> "warning"
  defp infer_discriminator_value(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/^Message/, "")
    |> String.downcase()
  end

  # Build sequential cast that tries each variant
  defp build_sequential_cast(variant_modules) do
    module_asts = Enum.map(variant_modules, &module_to_ast/1)

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

  # Convert module string to AST
  defp module_to_ast(module_string) when is_binary(module_string) do
    parts = module_string |> String.split(".") |> Enum.map(&String.to_atom/1)
    {:__aliases__, [alias: false], parts}
  end

  # Build the complete module AST
  defp build_module_ast(module_atom, schema, enum_attrs, fields, required_atoms) do
    moduledoc = build_moduledoc(schema)
    enum_attr_asts = build_enum_attrs(enum_attrs)
    fields_ast = build_fields_ast(fields)
    new_fn_ast = build_new_fn_ast(required_atoms)

    # Build body as flat list - avoid nested blocks that cause extra parens
    {new_doc, new_def} = new_fn_ast

    body =
      [
        moduledoc,
        quote(do: import(Ecto.Changeset))
      ] ++
        enum_attr_asts ++
        [
          fields_ast,
          quote(do: @doc("Returns the field definitions for this schema.")),
          quote(do: def(fields, do: @fields)),
          new_doc,
          new_def
        ]

    {:defmodule, [context: Elixir],
     [
       {:__aliases__, [alias: false], module_parts(module_atom)},
       [do: {:__block__, [], body}]
     ]}
  end

  # Extract module name parts for AST
  defp module_parts(module_atom) do
    module_atom
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  # Build @moduledoc attribute - returns {doc_content, ast}
  # We return the content separately so we can format it as heredoc in post-processing
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

    # Build a placeholder that we'll replace in post-processing
    {:@, [context: Elixir], [{:moduledoc, [context: Elixir], [doc_content]}]}
  end

  # Build enum module attributes
  defp build_enum_attrs([]), do: []

  defp build_enum_attrs(enum_attrs) do
    Enum.flat_map(enum_attrs, fn {name, values} ->
      values_attr = String.to_atom("#{name}_values")
      type_attr = String.to_atom("#{name}_type")
      atom_values = Enum.map(values, &to_safe_atom/1)

      [
        {:@, [context: Elixir], [{values_attr, [context: Elixir], [atom_values]}]},
        {:@, [context: Elixir],
         [
           {type_attr, [context: Elixir],
            [
              quote do
                Ecto.ParameterizedType.init(Ecto.Enum,
                  values: unquote({:@, [], [{values_attr, [], nil}]})
                )
              end
            ]}
         ]}
      ]
    end)
  end

  # Build @fields attribute with field definitions
  defp build_fields_ast(fields) do
    field_maps =
      Enum.map(fields, fn field ->
        # Build map pairs as AST - type is already AST, others need escaping
        pairs = [
          {Macro.escape(:name), Macro.escape(String.to_atom(field.name))},
          {Macro.escape(:type), field.type_ast}
        ]

        pairs =
          if field.description do
            pairs ++ [{Macro.escape(:description), Macro.escape(field.description)}]
          else
            pairs
          end

        pairs =
          if field.default do
            pairs ++ [{Macro.escape(:default), Macro.escape(field.default)}]
          else
            pairs
          end

        # Build %{key: value, ...} AST
        {:%{}, [], pairs}
      end)

    {:@, [context: Elixir], [{:fields, [context: Elixir], [field_maps]}]}
  end

  # Build new/1 function - returns {doc_ast, def_ast} to keep them separate
  defp build_new_fn_ast([]) do
    doc = quote(do: @doc("Creates a new changeset from params."))

    def_ast =
      quote do
        def new(params \\ %{}) do
          Schemecto.new(@fields, params)
        end
      end

    {doc, def_ast}
  end

  defp build_new_fn_ast(required_atoms) do
    doc = quote(do: @doc("Creates a new changeset from params."))

    def_ast =
      quote do
        def new(params \\ %{}) do
          Schemecto.new(@fields, params)
          |> validate_required(unquote(required_atoms))
        end
      end

    {doc, def_ast}
  end

  # Process properties and extract enum definitions
  defp process_properties(properties) do
    properties
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_reduce([], fn {name, prop}, enum_defs ->
      {type, type_opts} = TypeMapper.map_type(prop)

      # Handle enum types specially - create module attributes
      {type_ast, new_enum_defs} =
        case type do
          :enum ->
            values = type_opts[:values]
            type_attr = String.to_atom("#{name}_type")
            ast = {:@, [], [{type_attr, [], nil}]}
            {ast, [{name, values} | enum_defs]}

          :const ->
            value = type_opts[:value]
            type_attr = String.to_atom("#{name}_type")
            ast = {:@, [], [{type_attr, [], nil}]}
            {ast, [{name, [value]} | enum_defs]}

          _ ->
            {TypeMapper.to_type_ast({type, type_opts}), enum_defs}
        end

      field = %{
        name: name,
        type_ast: type_ast,
        description: prop["description"],
        default: type_opts[:default]
      }

      {field, new_enum_defs}
    end)
    |> then(fn {fields, enum_defs} ->
      {Enum.reverse(enum_defs), fields}
    end)
  end

  # Convert string to safe atom
  defp to_safe_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_safe_atom(value), do: value

  # Infer module name from schema
  defp infer_module_name(schema, opts) do
    prefix = opts[:module_prefix] || "Smelter.Generated"

    name =
      cond do
        schema[:_source_path] ->
          schema[:_source_path]
          |> Path.basename(".json")
          |> String.replace(~r/[._]/, " ")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join()

        schema["title"] ->
          schema["title"]
          |> String.replace(~r/[^a-zA-Z0-9\s]/, "")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join()

        true ->
          "Schema"
      end

    "#{prefix}.#{name}"
  end
end
