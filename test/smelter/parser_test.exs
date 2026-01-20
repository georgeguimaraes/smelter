defmodule Smelter.ParserTest do
  use ExUnit.Case, async: true

  alias Smelter.Parser

  @fixtures_path Path.expand("../fixtures", __DIR__)

  describe "parse_file/1" do
    test "parses a valid JSON schema file" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      assert {:ok, schema} = Parser.parse_file(path)
      assert is_map(schema)
      assert schema["title"] == "Simple Schema"
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = Parser.parse_file("/nonexistent.json")
    end

    test "returns error for invalid JSON" do
      # Create a temp file with invalid JSON
      path = Path.join(System.tmp_dir!(), "invalid_#{:rand.uniform(10000)}.json")
      File.write!(path, "{ invalid json }")

      # JSON module returns error tuples directly, not wrapped
      assert {:error, _} = Parser.parse_file(path)

      File.rm!(path)
    end
  end

  describe "parse_string/1" do
    test "parses valid JSON schema string" do
      json = ~s|{"type": "object", "properties": {"name": {"type": "string"}}}|
      assert {:ok, schema} = Parser.parse_string(json)
      assert schema["type"] == "object"
      assert schema["properties"]["name"]["type"] == "string"
    end

    test "returns error for invalid JSON string" do
      assert {:error, _} = Parser.parse_string("not json")
    end

    test "returns error for non-object schema" do
      assert {:error, :invalid_schema_structure} = Parser.parse_string("\"just a string\"")
    end
  end

  describe "extract_metadata/1" do
    test "extracts metadata from schema" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      {:ok, schema} = Parser.parse_file(path)
      metadata = Parser.extract_metadata(schema)

      assert metadata.title == "Simple Schema"
      assert metadata.description == "A simple test schema with basic properties."
      assert metadata.type == "object"
      assert metadata.required == ["name", "age"]
      assert metadata.has_properties == true
    end

    test "handles schema with compositions" do
      path = Path.join(@fixtures_path, "all_of_schema.json")
      {:ok, schema} = Parser.parse_file(path)
      metadata = Parser.extract_metadata(schema)

      assert metadata.has_all_of == true
    end
  end

  describe "generatable?/1" do
    test "returns true for schema with properties" do
      {:ok, schema} = Parser.parse_string(~s|{"type": "object", "properties": {}}|)
      assert Parser.generatable?(schema) == true
    end

    test "returns true for schema with allOf" do
      {:ok, schema} = Parser.parse_string(~s|{"allOf": []}|)
      assert Parser.generatable?(schema) == true
    end

    test "returns true for schema with oneOf" do
      {:ok, schema} = Parser.parse_string(~s|{"oneOf": []}|)
      assert Parser.generatable?(schema) == true
    end

    test "returns false for empty schema" do
      {:ok, schema} = Parser.parse_string(~s|{}|)
      assert Parser.generatable?(schema) == false
    end
  end
end
