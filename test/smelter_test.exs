defmodule SmelterTest do
  use ExUnit.Case, async: true

  @fixtures_path Path.expand("fixtures", __DIR__)

  describe "parse/2" do
    test "parses a simple schema file" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      assert {:ok, schema} = Smelter.parse(path)
      assert schema["title"] == "Simple Schema"
      assert schema["properties"]["name"]["type"] == "string"
      assert schema["required"] == ["name", "age"]
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} = Smelter.parse("/nonexistent/path.json")
    end
  end

  describe "generate/2" do
    test "generates code from a simple schema" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      {:ok, schema} = Smelter.parse(path)
      code = Smelter.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "defmodule Test.SimpleSchema do"
      assert code =~ "@moduledoc"
      assert code =~ "Simple Schema"
      assert code =~ "embedded_schema"
      assert code =~ "def changeset"
      assert code =~ "def new"
      assert code =~ ":name"
      assert code =~ ":age"
    end

    test "generates code with required field validation" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      {:ok, schema} = Smelter.parse(path)
      code = Smelter.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "validate_required([:age, :name])" or
               code =~ "validate_required([:name, :age])"
    end
  end

  describe "compile/2" do
    test "parses and generates in one step" do
      path = Path.join(@fixtures_path, "simple_schema.json")
      assert {:ok, code} = Smelter.compile(path, module: "Test.Compiled")
      assert code =~ "defmodule Test.Compiled do"
    end

    test "returns error for invalid file" do
      assert {:error, _} = Smelter.compile("/nonexistent/path.json")
    end
  end
end
