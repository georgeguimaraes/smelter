defmodule Smelter.ResolverTest do
  use ExUnit.Case, async: true

  alias Smelter.Resolver

  @fixtures_path Path.expand("../fixtures", __DIR__)

  describe "resolve/3" do
    test "resolves a simple schema without refs" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)
      assert resolved["title"] == "Simple Schema"
      assert resolved[:_source_path] == path
    end

    test "resolves local $ref to $defs" do
      path = Path.join(@fixtures_path, "ref_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # The price and discount properties should have the money schema resolved
      price = resolved["properties"]["price"]
      assert price[:_ref] == "#/$defs/money"
      assert price["properties"]["amount"]["type"] == "integer"
      assert price["properties"]["currency"]["type"] == "string"
    end

    test "resolves file $ref to another schema" do
      path = Path.join(@fixtures_path, "ref_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # The item property should have ref metadata
      item = resolved["properties"]["item"]
      assert item[:_ref] == "item.json"
      assert item[:_ref_module] =~ "Item"
    end

    test "resolves allOf with file ref" do
      path = Path.join(@fixtures_path, "all_of_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # allOf should merge properties from both schemas
      # The extended schema has: title, description from itself
      # Plus: id, created_at from base
      assert resolved["title"] == "Extended Schema"
      assert resolved["properties"]["id"]["type"] == "string"
      assert resolved["properties"]["created_at"]["format"] == "date-time"
      assert resolved["properties"]["name"]["type"] == "string"
      assert resolved["properties"]["description"]["type"] == "string"

      # required should be merged and deduplicated
      assert "id" in resolved["required"]
      assert "name" in resolved["required"]
    end

    test "resolves oneOf variants" do
      path = Path.join(@fixtures_path, "one_of_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # oneOf should be preserved with ref metadata on each variant
      assert {:one_of, variants} = resolved[:_composition]
      assert length(variants) == 2

      # Each variant should have ref metadata
      [error_variant, warning_variant] = variants
      assert error_variant[:_ref] == "one_of_message_error.json"
      assert warning_variant[:_ref] == "one_of_message_warning.json"
    end

    test "resolves array items with file ref" do
      path = Path.join(@fixtures_path, "array_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # items should have ref metadata
      items_prop = resolved["properties"]["items"]
      assert items_prop["items"][:_ref] == "item.json"
    end
  end
end
