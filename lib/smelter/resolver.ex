defmodule Smelter.Resolver do
  @moduledoc """
  Resolves JSON Schema references ($ref) and definitions ($defs).

  Handles:
  - Local references: `#/$defs/name`
  - File references: `other.json`
  - Cross-file pointers: `other.json#/$defs/name`
  - Relative paths: `../parent.json`, `types/child.json`
  """

  @type schema :: map()
  @type opts :: keyword()

  @doc """
  Resolves all $ref in a schema, returning a fully resolved schema
  with metadata about the original references.
  """
  @spec resolve(schema(), Path.t(), opts()) :: {:ok, schema()} | {:error, term()}
  def resolve(schema, schema_path, opts \\ []) do
    expanded_path = Path.expand(schema_path)

    context = %{
      schema_path: expanded_path,
      # original_schema_path tracks where we started - used for relative file refs
      original_schema_path: expanded_path,
      schemas_dir: opts[:schemas_dir] || find_schemas_dir(schema_path),
      module_prefix: opts[:module_prefix] || "Smelter.Generated",
      cache: %{},
      root_schema: schema
    }

    case resolve_schema(schema, context) do
      {:ok, resolved, _context} -> {:ok, Map.put(resolved, :_source_path, schema_path)}
      {:error, _} = error -> error
    end
  end

  # Resolve a schema node, handling $ref and recursive structures
  # For file refs, we just annotate with module info but don't recursively resolve
  # to avoid path confusion when processing sibling properties
  defp resolve_schema(%{"$ref" => ref} = schema, context) do
    case parse_ref(ref) do
      {:local, _pointer} ->
        # Local refs within the same file - resolve fully
        case resolve_ref(ref, context) do
          {:ok, resolved, new_context} ->
            merged =
              schema
              |> Map.delete("$ref")
              |> Map.merge(resolved, fn _k, v1, _v2 -> v1 end)
              |> Map.put(:_ref, ref)
              |> Map.put(:_ref_module, ref_to_module(ref, context))

            {:ok, merged, new_context}

          error ->
            error
        end

      {:file, _file_path, _pointer} ->
        # File refs - just annotate with module info, don't recursively resolve
        # This avoids path confusion when processing sibling properties
        annotated =
          schema
          |> Map.put(:_ref, ref)
          |> Map.put(:_ref_module, ref_to_module(ref, context))

        {:ok, annotated, context}
    end
  end

  defp resolve_schema(%{"allOf" => schemas} = schema, context) do
    # allOf requires full resolution of all schemas including file refs
    # because we need to merge all properties together
    case resolve_all_fully(schemas, context) do
      {:ok, resolved_schemas, new_context} ->
        merged = merge_all_of(resolved_schemas)

        # Original schema metadata (title, description) takes precedence over allOf contents
        original_metadata = Map.delete(schema, "allOf")

        resolved =
          merged
          |> deep_merge(original_metadata)
          |> Map.put(:_composition, {:all_of, resolved_schemas})

        {:ok, resolved, new_context}

      error ->
        error
    end
  end

  defp resolve_schema(%{"oneOf" => schemas} = schema, context) do
    case resolve_all(schemas, context) do
      {:ok, resolved_schemas, new_context} ->
        resolved =
          schema
          |> Map.put("oneOf", resolved_schemas)
          |> Map.put(:_composition, {:one_of, resolved_schemas})

        {:ok, resolved, new_context}

      error ->
        error
    end
  end

  defp resolve_schema(%{"anyOf" => schemas} = schema, context) do
    case resolve_all(schemas, context) do
      {:ok, resolved_schemas, new_context} ->
        resolved =
          schema
          |> Map.put("anyOf", resolved_schemas)
          |> Map.put(:_composition, {:any_of, resolved_schemas})

        {:ok, resolved, new_context}

      error ->
        error
    end
  end

  defp resolve_schema(%{"properties" => props} = schema, context) do
    case resolve_properties(props, context) do
      {:ok, resolved_props, new_context} ->
        {:ok, Map.put(schema, "properties", resolved_props), new_context}

      error ->
        error
    end
  end

  defp resolve_schema(%{"items" => items} = schema, context) when is_map(items) do
    case resolve_schema(items, context) do
      {:ok, resolved_items, new_context} ->
        {:ok, Map.put(schema, "items", resolved_items), new_context}

      error ->
        error
    end
  end

  defp resolve_schema(schema, context) when is_map(schema) do
    {:ok, schema, context}
  end

  defp resolve_schema(schema, context) do
    {:ok, schema, context}
  end

  # Resolve a list of schemas
  defp resolve_all(schemas, context) do
    Enum.reduce_while(schemas, {:ok, [], context}, fn schema, {:ok, acc, ctx} ->
      case resolve_schema(schema, ctx) do
        {:ok, resolved, new_ctx} -> {:cont, {:ok, [resolved | acc], new_ctx}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved, ctx} -> {:ok, Enum.reverse(resolved), ctx}
      error -> error
    end
  end

  # Resolve a list of schemas with full resolution of file refs
  # Used for allOf where we need to merge all properties
  defp resolve_all_fully(schemas, context) do
    Enum.reduce_while(schemas, {:ok, [], context}, fn schema, {:ok, acc, ctx} ->
      case resolve_schema_fully(schema, ctx) do
        {:ok, resolved, new_ctx} -> {:cont, {:ok, [resolved | acc], new_ctx}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved, ctx} -> {:ok, Enum.reverse(resolved), ctx}
      error -> error
    end
  end

  # Resolve a schema, fully resolving file refs (for use in allOf)
  defp resolve_schema_fully(%{"$ref" => ref} = schema, context) do
    case resolve_ref(ref, context) do
      {:ok, resolved, new_context} ->
        merged =
          schema
          |> Map.delete("$ref")
          |> Map.merge(resolved, fn _k, v1, _v2 -> v1 end)
          |> Map.put(:_ref, ref)
          |> Map.put(:_ref_module, ref_to_module(ref, context))

        {:ok, merged, new_context}

      error ->
        error
    end
  end

  defp resolve_schema_fully(schema, context) do
    resolve_schema(schema, context)
  end

  # Resolve all properties in a properties map
  defp resolve_properties(props, context) do
    Enum.reduce_while(props, {:ok, %{}, context}, fn {name, prop}, {:ok, acc, ctx} ->
      case resolve_schema(prop, ctx) do
        {:ok, resolved, new_ctx} -> {:cont, {:ok, Map.put(acc, name, resolved), new_ctx}}
        error -> {:halt, error}
      end
    end)
  end

  # Resolve a $ref string to its target schema
  defp resolve_ref(ref, context) do
    case parse_ref(ref) do
      {:local, pointer} ->
        resolve_local_ref(pointer, context)

      {:file, file_path, nil} ->
        resolve_file_ref(file_path, nil, context)

      {:file, file_path, pointer} ->
        resolve_file_ref(file_path, pointer, context)
    end
  end

  # Parse a $ref string into its components
  defp parse_ref("#" <> pointer), do: {:local, pointer}

  defp parse_ref(ref) do
    case String.split(ref, "#", parts: 2) do
      [file_path] -> {:file, file_path, nil}
      [file_path, pointer] -> {:file, file_path, pointer}
    end
  end

  # Resolve a local reference within the same schema
  defp resolve_local_ref(pointer, context) do
    path = pointer_to_path(pointer)

    case get_in(context.root_schema, path) do
      nil -> {:error, {:ref_not_found, "#" <> pointer}}
      target -> resolve_schema(target, context)
    end
  end

  # Resolve a reference to another file
  defp resolve_file_ref(file_path, pointer, context) do
    full_path =
      file_path
      |> Path.expand(Path.dirname(context.schema_path))

    # Check cache first
    cache_key = {full_path, pointer}

    case Map.get(context.cache, cache_key) do
      nil ->
        case load_schema(full_path) do
          {:ok, schema} ->
            target =
              if pointer do
                path = pointer_to_path(pointer)
                get_in(schema, path)
              else
                schema
              end

            if target do
              new_context = %{
                context
                | schema_path: full_path,
                  root_schema: schema,
                  cache: Map.put(context.cache, cache_key, target)
              }

              resolve_schema(target, new_context)
            else
              {:error, {:ref_not_found, file_path <> "#" <> (pointer || "")}}
            end

          error ->
            error
        end

      cached ->
        {:ok, cached, context}
    end
  end

  # Load a schema file
  defp load_schema(path) do
    with {:ok, content} <- File.read(path),
         {:ok, schema} <- JSON.decode(content) do
      {:ok, schema}
    else
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  # Convert a JSON pointer to a path list
  defp pointer_to_path(pointer) do
    pointer
    |> String.trim_leading("/")
    |> String.split("/")
    |> Enum.map(&unescape_pointer/1)
  end

  # Unescape JSON pointer encoding
  defp unescape_pointer(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  # Merge multiple schemas from allOf
  defp merge_all_of(schemas) do
    Enum.reduce(schemas, %{}, &deep_merge(&2, &1))
  end

  # Deep merge two maps
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      # For lists (like required), concatenate and dedupe
      _key, v1, v2 when is_list(v1) and is_list(v2) -> Enum.uniq(v1 ++ v2)
      _key, _v1, v2 -> v2
    end)
  end

  defp deep_merge(_base, override), do: override

  # Convert a $ref to a module name
  defp ref_to_module(ref, context) do
    {file_path, pointer} =
      case parse_ref(ref) do
        {:local, pointer} -> {context.schema_path, pointer}
        {:file, file, nil} -> {Path.expand(file, Path.dirname(context.schema_path)), nil}
        {:file, file, ptr} -> {Path.expand(file, Path.dirname(context.schema_path)), ptr}
      end

    base_module = path_to_module(file_path, context)

    if pointer do
      # Add the $defs name to the module
      def_name =
        pointer
        |> String.trim_leading("/$defs/")
        |> String.trim_leading("/")
        |> Macro.camelize()

      "#{base_module}.#{def_name}"
    else
      base_module
    end
  end

  # Convert a file path to a module name
  defp path_to_module(file_path, context) do
    relative =
      case find_relative_path(file_path, context.schemas_dir) do
        {:ok, rel} -> rel
        :error -> Path.basename(file_path, ".json")
      end

    module_suffix =
      relative
      |> Path.rootname(".json")
      |> String.split("/")
      |> Enum.map_join(".", fn part ->
        part
        |> String.replace(~r/[._]/, " ")
        |> String.split()
        |> Enum.map_join(&String.capitalize/1)
      end)

    "#{context.module_prefix}.#{module_suffix}"
  end

  # Find the relative path from schemas_dir
  defp find_relative_path(_file_path, nil), do: :error

  defp find_relative_path(file_path, schemas_dir) do
    expanded = Path.expand(file_path)
    expanded_dir = Path.expand(schemas_dir)

    if String.starts_with?(expanded, expanded_dir) do
      relative = Path.relative_to(expanded, expanded_dir)
      # Skip the version directory if present
      case Regex.run(~r|^[\d-]+/(.+)$|, relative) do
        [_, rest] -> {:ok, rest}
        nil -> {:ok, relative}
      end
    else
      :error
    end
  end

  # Find the schemas directory from a schema path
  defp find_schemas_dir(schema_path) do
    case Regex.run(~r|^(.+/ucp_schemas)/|, Path.expand(schema_path)) do
      [_, dir] -> dir
      nil -> Path.dirname(schema_path)
    end
  end
end
