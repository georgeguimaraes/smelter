defmodule Smelter.Generator do
  @moduledoc """
  Generates Elixir code from resolved JSON Schemas.

  Produces Ecto.Schema modules with `embedded_schema` and `changeset/2`.

  ## Usage

      Smelter.Generator.generate(schema, module: "MyApp.Schemas.Checkout")
  """

  alias Smelter.Generator.EctoSchema

  @doc """
  Generates Elixir module code from a resolved schema.

  ## Options

  - `:module` - Full module name
  - `:module_prefix` - Prefix for inferred module names (default: "Smelter.Generated")
  """
  def generate(schema, opts \\ []) do
    EctoSchema.generate(schema, opts)
  end
end
