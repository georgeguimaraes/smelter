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

    test "detects _ref_type :union for refs to oneOf schemas" do
      path = Path.join(@fixtures_path, "ref_to_union_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # The message property refs a oneOf schema, should be marked as union
      message = resolved["properties"]["message"]
      assert message[:_ref] == "one_of_schema.json"
      assert message[:_ref_type] == :union
    end

    test "detects _ref_type :regular for refs to regular schemas" do
      path = Path.join(@fixtures_path, "ref_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # The item property refs a regular schema, should be marked as regular
      item = resolved["properties"]["item"]
      assert item[:_ref] == "item.json"
      assert item[:_ref_type] == :regular
    end

    test "resolves anyOf variants" do
      path = Path.join(@fixtures_path, "any_of_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # anyOf should be preserved with ref metadata on each variant
      assert {:any_of, variants} = resolved[:_composition]
      assert length(variants) == 2

      # Each variant should have ref metadata
      [error_variant, warning_variant] = variants
      assert error_variant[:_ref] == "one_of_message_error.json"
      assert warning_variant[:_ref] == "one_of_message_warning.json"
    end

    test "detects _ref_type :union for refs to anyOf schemas" do
      # Create a schema that refs the anyOf schema
      schema = %{
        "type" => "object",
        "properties" => %{
          "message" => %{"$ref" => "any_of_schema.json"}
        }
      }

      path = Path.join(@fixtures_path, "test_ref_to_anyof.json")
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      message = resolved["properties"]["message"]
      assert message[:_ref_type] == :union
    end

    test "returns error for non-existent file ref" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "item" => %{"$ref" => "nonexistent.json"}
        }
      }

      path = Path.join(@fixtures_path, "test.json")
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # File refs that don't exist still get annotated (error happens at code gen time)
      item = resolved["properties"]["item"]
      assert item[:_ref] == "nonexistent.json"
      # _ref_type defaults to :regular when file can't be loaded
      assert item[:_ref_type] == :regular
    end

    test "returns error for non-existent local ref" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "item" => %{"$ref" => "#/$defs/nonexistent"}
        }
      }

      path = Path.join(@fixtures_path, "test.json")
      assert {:error, {:ref_not_found, "#/$defs/nonexistent"}} = Resolver.resolve(schema, path)
    end

    test "resolves schema without type" do
      schema = %{"title" => "Untyped"}
      path = Path.join(@fixtures_path, "test.json")
      assert {:ok, resolved} = Resolver.resolve(schema, path)
      assert resolved["title"] == "Untyped"
    end

    test "resolves items that is not a map" do
      schema = %{
        "type" => "array",
        "items" => true
      }

      path = Path.join(@fixtures_path, "test.json")
      assert {:ok, resolved} = Resolver.resolve(schema, path)
      assert resolved["items"] == true
    end

    test "uses custom module_prefix option" do
      path = Path.join(@fixtures_path, "ref_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})

      assert {:ok, resolved} = Resolver.resolve(schema, path, module_prefix: "Custom.Prefix")

      item = resolved["properties"]["item"]
      assert item[:_ref_module] =~ "Custom.Prefix"
    end

    test "inlines local refs to simple types (not generatable)" do
      path = Path.join(@fixtures_path, "simple_type_ref_schema.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # version should be inlined as string type, no _ref_module
      version = resolved["properties"]["version"]
      assert version["type"] == "string"
      assert version["pattern"] == "^\\d{4}-\\d{2}-\\d{2}$"
      assert version[:_ref] == "#/$defs/version"
      refute Map.has_key?(version, :_ref_module)

      # contact should be inlined as string with format
      contact = resolved["properties"]["contact"]
      assert contact["type"] == "string"
      assert contact["format"] == "email"
      refute Map.has_key?(contact, :_ref_module)
    end

    test "inlines file refs to simple types (not generatable)" do
      path = Path.join(@fixtures_path, "ref_to_simple_type.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # country_code refs a simple string type - should be inlined
      country_code = resolved["properties"]["country_code"]
      assert country_code["type"] == "string"
      assert country_code["pattern"] == "^[A-Z]{2,3}$"
      assert country_code[:_ref] == "simple_type.json"
      refute Map.has_key?(country_code, :_ref_module)
    end

    test "uses root_schema option for resolving local refs in $def entries" do
      path = Path.join(@fixtures_path, "defs_with_local_refs.json")
      {:ok, root_schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})

      # Extract the profile $def and resolve it with root_schema context
      profile_def = root_schema["$defs"]["profile"]
      assert {:ok, resolved} = Resolver.resolve(profile_def, path, root_schema: root_schema)

      # version should be resolved from root schema's $defs
      version = resolved["properties"]["version"]
      assert version["type"] == "string"
      assert version["pattern"] == "^\\d{4}-\\d{2}-\\d{2}$"
      assert version[:_ref] == "#/$defs/version"
      refute Map.has_key?(version, :_ref_module)
    end

    test "fails to resolve local refs in $def without root_schema" do
      path = Path.join(@fixtures_path, "defs_with_local_refs.json")
      {:ok, root_schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})

      # Extract the profile $def and try to resolve without root_schema
      profile_def = root_schema["$defs"]["profile"]

      # Should fail because #/$defs/version doesn't exist in profile_def
      assert {:error, {:ref_not_found, "#/$defs/version"}} = Resolver.resolve(profile_def, path)
    end

    test "preserves context for local refs in allOf siblings after file ref" do
      # This tests the fix for context isolation: when allOf has a file ref
      # followed by a schema with local refs, the local refs should resolve
      # from the original schema, not from the file ref's schema.
      path = Path.join(@fixtures_path, "allof_sibling_context.json")
      {:ok, schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})
      assert {:ok, resolved} = Resolver.resolve(schema, path)

      # The allOf should merge successfully
      assert resolved["title"] == "AllOf Sibling Context Test"

      # Properties from file ref (all_of_base.json) should be merged
      assert resolved["properties"]["id"]["type"] == "string"
      assert resolved["properties"]["created_at"]["format"] == "date-time"

      # Local ref in sibling should resolve correctly from original schema
      extension = resolved["properties"]["extension"]
      assert extension[:_ref] == "#/$defs/local_extension"
      assert extension["properties"]["extra_field"]["type"] == "string"
    end

    test "resolves $ref to root schema (#)" do
      path = Path.join(@fixtures_path, "root_self_ref.json")
      {:ok, root_schema} = File.read!(path) |> JSON.decode!() |> then(&{:ok, &1})

      # Resolve the extended $def which uses $ref: "#" to reference root
      extended_def = root_schema["$defs"]["extended"]
      assert {:ok, resolved} = Resolver.resolve(extended_def, path, root_schema: root_schema)

      # Should have merged properties from root schema and the extension
      assert resolved["title"] == "Extended Version"
      assert resolved["properties"]["id"]["type"] == "string"
      assert resolved["properties"]["name"]["type"] == "string"
      assert resolved["properties"]["selected"]["type"] == "boolean"
    end
  end
end
