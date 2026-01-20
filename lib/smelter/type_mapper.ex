defmodule Smelter.TypeMapper do
  @moduledoc """
  Maps JSON Schema types to Elixir/Ecto types.

  Handles:
  - Primitive types (string, integer, number, boolean, object, array)
  - Format specifiers (date-time, uri, email, uuid)
  - Enums and constants
  - Nullable types
  - Arrays with typed items
  - References to other schemas
  """

  @type json_type :: String.t() | [String.t()]
  @type ecto_type :: atom() | tuple() | String.t()
  @type property :: map()

  @doc """
  Maps a JSON Schema property to an Ecto type specification.

  Returns a tuple of `{type, opts}` where:
  - `type` is the Ecto type (atom, tuple, or string for complex types)
  - `opts` contains additional type metadata (enum values, constraints, etc.)
  """
  @spec map_type(property()) :: {ecto_type(), keyword()}
  def map_type(property) do
    cond do
      # Reference to another schema
      Map.has_key?(property, :_ref_module) ->
        map_ref_type(property)

      # Composition types
      Map.has_key?(property, :_composition) ->
        map_composition_type(property)

      # Const value (discriminator)
      Map.has_key?(property, "const") ->
        map_const_type(property)

      # Enum type
      Map.has_key?(property, "enum") ->
        map_enum_type(property)

      # Array type
      property["type"] == "array" ->
        map_array_type(property)

      # Nullable union type ["string", "null"]
      is_list(property["type"]) ->
        map_nullable_type(property)

      # Object type with properties (nested)
      property["type"] == "object" && Map.has_key?(property, "properties") ->
        map_nested_object_type(property)

      # Object type with additionalProperties (map)
      property["type"] == "object" ->
        map_object_type(property)

      # String with format
      property["type"] == "string" && Map.has_key?(property, "format") ->
        map_formatted_string_type(property)

      # Primitive types
      true ->
        map_primitive_type(property)
    end
  end

  # Map a $ref to Schemecto.one
  defp map_ref_type(property) do
    module = property[:_ref_module]
    {:ref, [module: module, cardinality: :one]}
  end

  # Map composition types (oneOf, anyOf, allOf)
  defp map_composition_type(property) do
    case property[:_composition] do
      {:one_of, schemas} ->
        variants = Enum.map(schemas, &extract_variant_info/1)
        {:union, [variants: variants, strategy: :one_of]}

      {:any_of, schemas} ->
        variants = Enum.map(schemas, &extract_variant_info/1)
        {:union, [variants: variants, strategy: :any_of]}

      {:all_of, _schemas} ->
        # allOf is already merged, treat as object
        if property["properties"] do
          map_nested_object_type(property)
        else
          {:map, []}
        end
    end
  end

  # Extract variant info for union types
  defp extract_variant_info(schema) do
    cond do
      Map.has_key?(schema, :_ref_module) ->
        %{type: :ref, module: schema[:_ref_module]}

      schema["const"] ->
        %{type: :const, value: schema["const"]}

      schema["properties"] && Map.has_key?(schema["properties"], "type") &&
          schema["properties"]["type"]["const"] ->
        # Discriminated union
        discriminator = schema["properties"]["type"]["const"]
        %{type: :discriminated, discriminator: discriminator, schema: schema}

      true ->
        %{type: :inline, schema: schema}
    end
  end

  # Map const type (fixed value)
  defp map_const_type(property) do
    value = property["const"]
    {:const, [value: value]}
  end

  # Map enum type
  defp map_enum_type(property) do
    values = property["enum"]
    {:enum, [values: values]}
  end

  # Map array type
  defp map_array_type(property) do
    items = property["items"]

    cond do
      is_nil(items) ->
        {{:array, :map}, []}

      Map.has_key?(items, :_ref_module) ->
        module = items[:_ref_module]
        {:ref, [module: module, cardinality: :many]}

      items["type"] ->
        {inner_type, inner_opts} = map_type(items)
        # Preserve inner type opts for complex types like enums
        {:array_of, [inner_type: inner_type, inner_opts: inner_opts]}

      true ->
        {{:array, :map}, []}
    end
  end

  # Map nullable types like ["string", "null"]
  defp map_nullable_type(property) do
    types = property["type"]
    non_null_types = Enum.reject(types, &(&1 == "null"))

    case non_null_types do
      [single_type] ->
        {type, opts} = map_type(Map.put(property, "type", single_type))
        {type, Keyword.put(opts, :nullable, true)}

      _multiple ->
        # Multiple non-null types, treat as any
        {:map, [nullable: true]}
    end
  end

  # Map nested object with properties
  defp map_nested_object_type(property) do
    properties = property["properties"] || %{}
    required = property["required"] || []

    fields =
      Enum.map(properties, fn {name, prop} ->
        {type, opts} = map_type(prop)
        is_required = name in required

        %{
          name: name,
          type: type,
          type_opts: opts,
          required: is_required,
          description: prop["description"]
        }
      end)

    {:embedded, [fields: fields]}
  end

  # Map generic object type (map)
  defp map_object_type(property) do
    additional = property["additionalProperties"]

    cond do
      is_map(additional) && Map.has_key?(additional, :_ref_module) ->
        # Map with typed values
        module = additional[:_ref_module]
        {:map, [value_type: {:ref, module}]}

      is_map(additional) && additional["type"] ->
        {value_type, _opts} = map_type(additional)
        {:map, [value_type: value_type]}

      true ->
        {:map, []}
    end
  end

  # Map string with format specifier
  defp map_formatted_string_type(property) do
    case property["format"] do
      "date-time" -> {:utc_datetime, []}
      "date" -> {:date, []}
      "time" -> {:time, []}
      "uri" -> {:string, [format: :uri]}
      "email" -> {:string, [format: :email]}
      "uuid" -> {:binary_id, []}
      "ipv4" -> {:string, [format: :ipv4]}
      "ipv6" -> {:string, [format: :ipv6]}
      format -> {:string, [format: format]}
    end
  end

  # Map primitive JSON Schema types to Ecto types
  defp map_primitive_type(property) do
    type =
      case property["type"] do
        "string" -> :string
        "integer" -> :integer
        "number" -> :float
        "boolean" -> :boolean
        "object" -> :map
        "array" -> {:array, :map}
        nil -> :map
        _ -> :map
      end

    opts = extract_constraints(property)
    {type, opts}
  end

  # Extract validation constraints from property
  defp extract_constraints(property) do
    []
    |> maybe_add(:minimum, property["minimum"])
    |> maybe_add(:maximum, property["maximum"])
    |> maybe_add(:exclusive_minimum, property["exclusiveMinimum"])
    |> maybe_add(:exclusive_maximum, property["exclusiveMaximum"])
    |> maybe_add(:min_length, property["minLength"])
    |> maybe_add(:max_length, property["maxLength"])
    |> maybe_add(:pattern, property["pattern"])
    |> maybe_add(:default, property["default"])
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Converts a mapped type to an Ecto type specification string.
  """
  @spec to_ecto_type({ecto_type(), keyword()}) :: String.t()
  def to_ecto_type({:string, _opts}), do: ":string"
  def to_ecto_type({:integer, _opts}), do: ":integer"
  def to_ecto_type({:float, _opts}), do: ":float"
  def to_ecto_type({:boolean, _opts}), do: ":boolean"
  def to_ecto_type({:map, _opts}), do: ":map"
  def to_ecto_type({:utc_datetime, _opts}), do: ":utc_datetime"
  def to_ecto_type({:date, _opts}), do: ":date"
  def to_ecto_type({:time, _opts}), do: ":time"
  def to_ecto_type({:binary_id, _opts}), do: ":binary_id"
  def to_ecto_type({{:array, inner}, _opts}), do: "{:array, #{to_ecto_type({inner, []})}}"

  def to_ecto_type({:array_of, opts}) do
    inner_type = opts[:inner_type]
    _inner_opts = opts[:inner_opts] || []

    case inner_type do
      # Simple primitive types
      type when type in [:string, :integer, :float, :boolean, :map] ->
        "{:array, :#{type}}"

      :utc_datetime ->
        "{:array, :utc_datetime}"

      # Complex types - just use :map for arrays of complex objects
      _ ->
        "{:array, :map}"
    end
  end

  def to_ecto_type({:enum, opts}) do
    values = opts[:values] |> Enum.map(&String.to_atom/1) |> inspect()
    "Ecto.ParameterizedType.init(Ecto.Enum, values: #{values})"
  end

  def to_ecto_type({:const, opts}) do
    # Constants are typically handled as enums with one value
    value = opts[:value]
    "Ecto.ParameterizedType.init(Ecto.Enum, values: [#{inspect(String.to_atom(value))}])"
  end

  def to_ecto_type({:ref, opts}) do
    module = opts[:module]
    cardinality = opts[:cardinality] || :one

    case cardinality do
      :one -> "Schemecto.one(#{module}.fields(), with: &Function.identity/1)"
      :many -> "Schemecto.many(#{module}.fields(), with: &Function.identity/1)"
    end
  end

  def to_ecto_type({:union, _opts}) do
    # Unions are complex - for now, map to :map
    ":map"
  end

  def to_ecto_type({:embedded, _opts}) do
    # Inline embedded objects - for now, map to :map
    # A full implementation would generate inline field definitions
    ":map"
  end

  def to_ecto_type(_), do: ":map"

  @doc """
  Converts a mapped type to an Elixir AST representation.
  """
  @spec to_type_ast({ecto_type(), keyword()}) :: Macro.t()
  def to_type_ast({:string, _opts}), do: :string
  def to_type_ast({:integer, _opts}), do: :integer
  def to_type_ast({:float, _opts}), do: :float
  def to_type_ast({:boolean, _opts}), do: :boolean
  def to_type_ast({:map, _opts}), do: :map
  def to_type_ast({:utc_datetime, _opts}), do: :utc_datetime
  def to_type_ast({:date, _opts}), do: :date
  def to_type_ast({:time, _opts}), do: :time
  def to_type_ast({:binary_id, _opts}), do: :binary_id
  def to_type_ast({{:array, inner}, opts}), do: {:array, to_type_ast({inner, opts})}

  def to_type_ast({:array_of, opts}) do
    inner_type = opts[:inner_type]
    _inner_opts = opts[:inner_opts] || []

    case inner_type do
      type when type in [:string, :integer, :float, :boolean, :map] ->
        {:array, type}

      :utc_datetime ->
        {:array, :utc_datetime}

      # Complex types - just use :map for arrays of complex objects
      _ ->
        {:array, :map}
    end
  end

  def to_type_ast({:ref, opts}) do
    module = opts[:module]
    module_ast = module_to_ast(module)
    cardinality = opts[:cardinality] || :one

    case cardinality do
      :one ->
        quote do
          Schemecto.one(unquote(module_ast).fields(), with: &Function.identity/1)
        end

      :many ->
        quote do
          Schemecto.many(unquote(module_ast).fields(), with: &Function.identity/1)
        end
    end
  end

  def to_type_ast({:union, _opts}), do: :map
  def to_type_ast({:embedded, _opts}), do: :map
  def to_type_ast({:enum, _opts}), do: :map
  def to_type_ast({:const, _opts}), do: :map
  def to_type_ast(_), do: :map

  # Convert module string to AST
  defp module_to_ast(module_string) when is_binary(module_string) do
    parts =
      module_string
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)

    {:__aliases__, [alias: false], parts}
  end
end
