defmodule Smelter.Generator do
  @moduledoc """
  Code generators for converting resolved JSON Schemas to Elixir code.

  Currently supports:
  - `Smelter.Generator.Schemecto` - Generates Schemecto-compatible modules
  """

  alias Smelter.Generator.Schemecto, as: Schemecto

  defdelegate generate(schema, opts \\ []), to: Schemecto
end
