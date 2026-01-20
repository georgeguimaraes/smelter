defmodule Smelter do
  @moduledoc """
  Smelter: JSON Schema to Elixir Code Generator

  Extracts pure Elixir types from raw JSON Schema ore. A robust library for
  generating Elixir code from JSON Schema definitions. Handles $ref resolution,
  oneOf/anyOf/allOf composition, nested objects, and generates Schemecto-compatible
  field definitions.

  ## Features

  - Full $ref resolution (local, cross-file, JSON pointers)
  - Schema composition (oneOf, anyOf, allOf)
  - Enum and const handling
  - Format specifiers (date-time, uri, email)
  - Nested object and array handling
  - Configurable code generation

  ## Usage

      # Parse and resolve a schema
      {:ok, schema} = Smelter.parse("path/to/schema.json")

      # Generate Elixir code
      code = Smelter.generate(schema, module: "MyApp.Schemas.User")

  ## Configuration

  Smelter can be configured with:

  - `:module_prefix` - Base module prefix for generated schemas
  - `:schemas_dir` - Base directory for schema resolution
  - `:generator` - Code generator module (default: `Smelter.Generator.Schemecto`)
  """

  alias Smelter.{Resolver, Generator}

  @type schema :: map()
  @type opts :: keyword()

  @doc """
  Parses a JSON Schema file and resolves all references.

  Returns `{:ok, resolved_schema}` or `{:error, reason}`.
  """
  @spec parse(Path.t(), opts()) :: {:ok, schema()} | {:error, term()}
  def parse(schema_path, opts \\ []) do
    with {:ok, content} <- File.read(schema_path),
         {:ok, schema} <- JSON.decode(content),
         {:ok, resolved} <- Resolver.resolve(schema, schema_path, opts) do
      {:ok, resolved}
    end
  end

  @doc """
  Generates Elixir code from a resolved schema.

  ## Options

  - `:module` - Full module name for the generated schema
  - `:module_prefix` - Prefix for inferred module names (default: "Smelter.Generated")
  - `:generator` - Generator module (default: `Smelter.Generator.Schemecto`)
  """
  @spec generate(schema(), opts()) :: String.t()
  def generate(schema, opts \\ []) do
    generator = opts[:generator] || Generator.Schemecto
    generator.generate(schema, opts)
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
