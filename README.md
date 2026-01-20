# Smelter 🔥⚗️

JSON Schema to Elixir code generator. Extracts pure Elixir types from raw JSON Schema ore.

Generates [Schemecto](https://github.com/josevalim/schemecto)-compatible modules that provide `new/1` for validation and `fields/0` for introspection.

## Features

- Full `$ref` resolution (local, cross-file, JSON pointers)
- Schema composition (`oneOf`, `anyOf`, `allOf`)
- `$defs` extraction and module generation
- Enum and const handling
- Format specifiers (date-time, uri, email, uuid)
- Nested object and array handling
- Batch generation from schema directories

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

### Single Schema

```elixir
# Parse and resolve a schema
{:ok, schema} = Smelter.parse("path/to/schema.json")

# Generate Elixir code
code = Smelter.generate(schema, module: "MyApp.Schemas.User")

# Or do both in one step
{:ok, code} = Smelter.compile("path/to/schema.json", module: "MyApp.Schemas.User")
```

### Batch Generation

Smelter can process entire directories of JSON Schemas, preserving the folder structure:

```elixir
Smelter.Batch.generate(
  schema_dir: "priv/schemas/2026-01-11",
  output_dir: "lib/my_app/schemas",
  module_prefix: "MyApp.Schemas"
)
```

This processes all `.json` files in the directory, including:
- Root schemas with `properties`
- Union schemas (`oneOf`/`anyOf`)
- `$defs` entries within schemas

## Generated Code

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

Generates union type modules that delegate to the appropriate variant:

```json
{
  "oneOf": [
    { "$ref": "error.json" },
    { "$ref": "warning.json" }
  ]
}
```

Generated code uses a discriminator field (commonly `type`) to route to the correct schema module.

### $defs

Entries in `$defs` are extracted and generated as separate modules. A schema like:

```json
{
  "$defs": {
    "Address": {
      "type": "object",
      "properties": { "city": { "type": "string" } }
    }
  }
}
```

Generates `MyApp.Schemas.ContainerName.Address` module.

## Real-World Usage: Bazaar

[Bazaar](https://github.com/georgeguimaraes/bazaar) uses Smelter to generate UCP schemas:

```bash
mix bazaar.gen.schemas priv/ucp_schemas/2026-01-11
```

This generates all Elixir modules in `lib/bazaar/schemas/` from the official UCP JSON Schemas.

## License

Apache-2.0
