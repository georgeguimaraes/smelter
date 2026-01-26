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

  ## Options

  - `:schemas_dir` - Directory containing schema files for resolving file refs
  - `:module_prefix` - Prefix for generated module names (default: "Smelter.Generated")
  - `:root_schema` - Root schema for resolving local refs (default: the schema being resolved).
    Use this when resolving a $def entry that needs access to sibling $defs.
  """
  @spec resolve(schema(), Path.t(), opts()) :: {:ok, schema()} | {:error, term()}
  def resolve(schema, schema_path, opts \\ []) do
    expanded_path = Path.expand(schema_path)

    # Allow passing a root_schema for resolving local refs in $def entries
    root_schema = opts[:root_schema] || schema

    context = %{
      schema_path: expanded_path,
      # original_schema_path tracks where we started - used for relative file refs
      original_schema_path: expanded_path,
      schemas_dir: opts[:schemas_dir] || find_schemas_dir(schema_path),
      module_prefix: opts[:module_prefix] || "Smelter.Generated",
      root_schema: root_schema
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
            # Only add _ref_module if the resolved schema is generatable (has properties or composition)
            # Simple types like {"type": "string"} should be inlined without a module reference
            merged =
              schema
              |> Map.delete("$ref")
              |> Map.merge(resolved, fn _k, v1, _v2 -> v1 end)
              |> Map.put(:_ref, ref)

            merged =
              if generatable_schema?(resolved) do
                merged
                |> Map.put(:_ref_module, ref_to_module(ref, context))
                |> Map.put(:_ref_type, determine_schema_ref_type(resolved))
              else
                merged
              end

            {:ok, merged, new_context}

          error ->
            error
        end

      {:file, file_path, pointer} ->
        resolve_file_ref(schema, ref, file_path, pointer, context)
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

  # Helper functions for file ref resolution (must be after all resolve_schema clauses)

  defp resolve_file_ref(schema, ref, file_path, pointer, context) do
    full_path = Path.expand(file_path, Path.dirname(context.schema_path))

    case load_and_get_target(full_path, pointer) do
      {:ok, target_schema} ->
        resolve_file_ref_target(schema, ref, target_schema, full_path, context)

      {:error, _} ->
        # Fallback to just annotating with module
        ref_type = determine_ref_type(full_path, pointer)

        annotated =
          schema
          |> Map.put(:_ref, ref)
          |> Map.put(:_ref_module, ref_to_module(ref, context))
          |> Map.put(:_ref_type, ref_type)

        {:ok, annotated, context}
    end
  end

  defp resolve_file_ref_target(schema, ref, target_schema, _full_path, context) do
    if generatable_schema?(target_schema) do
      ref_type = determine_ref_type_from_schema(target_schema)

      annotated =
        schema
        |> Map.put(:_ref, ref)
        |> Map.put(:_ref_module, ref_to_module(ref, context))
        |> Map.put(:_ref_type, ref_type)

      {:ok, annotated, context}
    else
      # Target is a simple type - resolve it inline
      resolve_simple_ref_inline(schema, ref, context)
    end
  end

  defp resolve_simple_ref_inline(schema, ref, context) do
    case resolve_ref(ref, context) do
      {:ok, resolved, new_context} ->
        merged =
          schema
          |> Map.delete("$ref")
          |> Map.merge(resolved, fn _k, v1, _v2 -> v1 end)
          |> Map.put(:_ref, ref)

        {:ok, merged, new_context}

      error ->
        error
    end
  end

  # Resolve a list of schemas, preserving original context for each.
  # This prevents file ref resolution from polluting sibling schemas
  # (e.g., changing root_schema would break local refs in siblings).
  defp resolve_all(schemas, context) do
    schemas
    |> map_ok(&resolve_schema(&1, context))
    |> wrap_context(context)
  end

  # Resolve a list of schemas with full resolution of file refs.
  # Used for allOf where we need to merge all properties.
  defp resolve_all_fully(schemas, context) do
    schemas
    |> map_ok(&resolve_schema_fully(&1, context))
    |> wrap_context(context)
  end

  # Maps over a list, stopping on first error. Returns {:ok, results} or {:error, reason}.
  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, resolved, _ctx} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end)
  end

  # Wraps a result with context for the resolver's return signature.
  defp wrap_context({:ok, resolved}, context), do: {:ok, resolved, context}
  defp wrap_context(error, _context), do: error

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

  # Resolve all properties in a properties map.
  # Each property is resolved with the original context to prevent cross-contamination.
  defp resolve_properties(props, context) do
    props
    |> Enum.reduce_while({:ok, %{}}, fn {name, prop}, {:ok, acc} ->
      case resolve_schema(prop, context) do
        {:ok, resolved, _ctx} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> wrap_context(context)
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
    # Empty pointer means root schema itself
    if pointer == "" do
      resolve_schema(context.root_schema, context)
    else
      path = pointer_to_path(pointer)

      case get_in(context.root_schema, path) do
        nil -> {:error, {:ref_not_found, "#" <> pointer}}
        target -> resolve_schema(target, context)
      end
    end
  end

  # Resolve a reference to another file
  defp resolve_file_ref(file_path, pointer, context) do
    full_path = Path.expand(file_path, Path.dirname(context.schema_path))

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
          new_context = %{context | schema_path: full_path, root_schema: schema}
          resolve_schema(target, new_context)
        else
          {:error, {:ref_not_found, file_path <> "#" <> (pointer || "")}}
        end

      error ->
        error
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

  # Load schema file and extract target at pointer
  defp load_and_get_target(file_path, pointer) do
    case load_schema(file_path) do
      {:ok, schema} ->
        target =
          if pointer do
            path = pointer_to_path(pointer)
            get_in(schema, path)
          else
            schema
          end

        if target do
          {:ok, target}
        else
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  # Determine ref type from already-loaded schema
  defp determine_ref_type_from_schema(schema) when is_map(schema) do
    if Map.has_key?(schema, "oneOf") or Map.has_key?(schema, "anyOf") do
      :union
    else
      :regular
    end
  end

  defp determine_ref_type_from_schema(_), do: :regular

  # Determine the type of schema a ref points to (union or regular)
  defp determine_ref_type(file_path, pointer) do
    case load_and_get_target(file_path, pointer) do
      {:ok, target} -> determine_ref_type_from_schema(target)
      {:error, _} -> :regular
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

  # Check if a schema is generatable (has properties or composition types)
  # Simple types like {"type": "string"} are not generatable and should be inlined
  defp generatable_schema?(schema) when is_map(schema) do
    Map.has_key?(schema, "properties") or
      Map.has_key?(schema, "oneOf") or
      Map.has_key?(schema, "anyOf") or
      Map.has_key?(schema, "allOf")
  end

  defp generatable_schema?(_), do: false

  # Determine if a resolved schema is a union type
  defp determine_schema_ref_type(schema) when is_map(schema) do
    if Map.has_key?(schema, "oneOf") or Map.has_key?(schema, "anyOf") do
      :union
    else
      :regular
    end
  end

  defp determine_schema_ref_type(_), do: :regular
end
