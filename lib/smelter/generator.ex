defmodule Smelter.Generator do
  @moduledoc """
  Code generators for converting resolved JSON Schemas to Elixir code.

  ## Generators

  - `:schemecto` (default) - Generates Schemecto-compatible modules with `@fields` and `new/1`
  - `:ecto_schema` - Generates pure Ecto.Schema modules with `embedded_schema` and `changeset/2`

  ## Usage

      # Default (Schemecto)
      Smelter.Generator.generate(schema, module: "MyApp.Schemas.Checkout")

      # Pure Ecto.Schema
      Smelter.Generator.generate(schema, format: :ecto_schema, module: "MyApp.Schemas.Checkout")
  """

  alias Smelter.Generator.EctoSchema
  alias Smelter.Generator.Schemecto

  @doc """
  Generates Elixir module code from a resolved schema.

  ## Options

  - `:format` - Generator format: `:schemecto` (default) or `:ecto_schema`
  - `:module` - Full module name
  - `:module_prefix` - Prefix for inferred module names (default: "Smelter.Generated")
  """
  def generate(schema, opts \\ []) do
    format = Keyword.get(opts, :format, :schemecto)

    case format do
      :schemecto -> Schemecto.generate(schema, opts)
      :ecto_schema -> EctoSchema.generate(schema, opts)
      other -> raise ArgumentError, "Unknown generator format: #{inspect(other)}"
    end
  end
end
