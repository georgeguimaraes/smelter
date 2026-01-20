defmodule Smelter.Parser do
  @moduledoc """
  Parses JSON Schema files and validates their structure.

  This module handles:
  - Loading JSON Schema files from disk
  - Basic structural validation
  - Extracting schema metadata (title, description, etc.)
  """

  @doc """
  Parses a JSON Schema file from the given path.

  Returns `{:ok, schema}` on success, or `{:error, reason}` on failure.
  """
  @spec parse_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, schema} <- JSON.decode(content),
         :ok <- validate_schema(schema) do
      {:ok, schema}
    else
      {:error, %JSON.DecodeError{} = error} ->
        {:error, {:json_parse_error, path, error}}

      {:error, :enoent} ->
        {:error, {:file_not_found, path}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:file_error, path, reason}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Parses a JSON Schema from a string.
  """
  @spec parse_string(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_string(content) do
    with {:ok, schema} <- JSON.decode(content),
         :ok <- validate_schema(schema) do
      {:ok, schema}
    end
  end

  @doc """
  Extracts metadata from a schema.
  """
  @spec extract_metadata(map()) :: map()
  def extract_metadata(schema) do
    %{
      id: schema["$id"],
      schema_version: schema["$schema"],
      title: schema["title"],
      description: schema["description"],
      type: schema["type"],
      required: schema["required"] || [],
      has_properties: Map.has_key?(schema, "properties"),
      has_defs: Map.has_key?(schema, "$defs"),
      has_all_of: Map.has_key?(schema, "allOf"),
      has_one_of: Map.has_key?(schema, "oneOf"),
      has_any_of: Map.has_key?(schema, "anyOf")
    }
  end

  @doc """
  Checks if a schema is generatable (has properties to generate).
  """
  @spec generatable?(map()) :: boolean()
  def generatable?(schema) do
    # A schema is generatable if it has properties or is a composition
    Map.has_key?(schema, "properties") ||
      Map.has_key?(schema, "allOf") ||
      Map.has_key?(schema, "oneOf") ||
      Map.has_key?(schema, "anyOf")
  end

  # Basic validation of schema structure
  defp validate_schema(schema) when is_map(schema), do: :ok
  defp validate_schema(_), do: {:error, :invalid_schema_structure}
end
