# Smelter 🔥⚗️

JSON Schema to Elixir code generator. Extracts pure Elixir types from raw JSON Schema ore.

## Features

- Full `$ref` resolution (local, cross-file, JSON pointers)
- Schema composition (`oneOf`, `anyOf`, `allOf`)
- Enum and const handling
- Format specifiers (date-time, uri, email, uuid)
- Nested object and array handling
- Generates [Schemecto](https://github.com/josevalim/schemecto)-compatible modules

## Installation

Add `smelter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:smelter, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Parse and resolve a schema
{:ok, schema} = Smelter.parse("path/to/schema.json")

# Generate Elixir code
code = Smelter.generate(schema, module: "MyApp.Schemas.User")

# Or do both in one step
{:ok, code} = Smelter.compile("path/to/schema.json", module: "MyApp.Schemas.User")
```

### Generated Code

Given a JSON Schema like:

```json
{
  "title": "User",
  "type": "object",
  "required": ["name", "email"],
  "properties": {
    "name": { "type": "string" },
    "email": { "type": "string", "format": "email" },
    "age": { "type": "integer", "minimum": 0 }
  }
}
```

Smelter generates:

```elixir
defmodule MyApp.Schemas.User do
  @moduledoc """
  User
  """
  import Ecto.Changeset

  @fields [
    %{name: :age, type: :integer},
    %{name: :email, type: :string},
    %{name: :name, type: :string}
  ]

  @doc "Returns the field definitions for this schema."
  def fields, do: @fields

  @doc "Creates a new changeset from params."
  def new(params \\ %{}) do
    Schemecto.new(@fields, params)
    |> validate_required([:email, :name])
  end
end
```

## Schema Composition

Smelter handles JSON Schema composition keywords:

### allOf

Properties from all schemas are merged together:

```json
{
  "allOf": [
    { "$ref": "base.json" },
    { "properties": { "extra": { "type": "string" } } }
  ]
}
```

### oneOf / anyOf

Generates union type modules with variant detection:

```json
{
  "oneOf": [
    { "$ref": "error.json" },
    { "$ref": "warning.json" }
  ]
}
```

## License

Apache-2.0
