defmodule Smelter do
  @moduledoc """
  Smelter: JSON Schema to Elixir Code Generator

  Extracts pure Elixir types from raw JSON Schema ore. Generates Ecto.Schema
  modules from JSON Schema definitions with full $ref resolution and schema
  composition support.

  ## Features

  - Full $ref resolution (local, cross-file, JSON pointers)
  - Schema composition (oneOf, anyOf, allOf)
  - Enum and const handling
  - Format specifiers (date-time, uri, email, uuid)
  - Nested object and array handling
  - Batch generation from schema directories

  ## Usage

      # Parse and resolve a schema
      {:ok, schema} = Smelter.parse("path/to/schema.json")

      # Generate Elixir code
      code = Smelter.generate(schema, module: "MyApp.Schemas.User")

      # Or do both in one step
      {:ok, code} = Smelter.compile("path/to/schema.json", module: "MyApp.Schemas.User")

  ## Configuration

  Smelter can be configured with:

  - `:module` - Full module name for generated schema
  - `:module_prefix` - Base module prefix for generated schemas
  - `:schemas_dir` - Base directory for schema resolution
  """

  alias Smelter.{Generator, Resolver}

  @type schema :: map()
  @type opts :: keyword()

  @doc """
  Parses a JSON Schema file and resolves all references.

  Returns `{:ok, resolved_schema}` or `{:error, reason}`.
  """
  @spec parse(Path.t(), opts()) :: {:ok, schema()} | {:error, term()}
  def parse(schema_path, opts \\ []) do
    with {:ok, content} <- File.read(schema_path),
         {:ok, schema} <- JSON.decode(content) do
      Resolver.resolve(schema, schema_path, opts)
    end
  end

  @doc """
  Generates Elixir code from a resolved schema.

  ## Options

  - `:module` - Full module name for the generated schema
  - `:module_prefix` - Prefix for inferred module names (default: "Smelter.Generated")
  """
  @spec generate(schema(), opts()) :: String.t()
  def generate(schema, opts \\ []) do
    Generator.generate(schema, opts)
  end

  @doc """
  Parses and generates code in one step.
  """
  @spec compile(Path.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def compile(schema_path, opts \\ []) do
    case parse(schema_path, opts) do
      {:ok, schema} -> {:ok, generate(schema, opts)}
      error -> error
    end
  end
end
