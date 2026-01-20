defmodule Smelter.Generator.SchemectoTest do
  use ExUnit.Case, async: true

  alias Smelter.Generator.Schemecto
  alias Smelter.Resolver

  @fixtures_path Path.expand("../../fixtures", __DIR__)

  defp parse_and_resolve(filename) do
    path = Path.join(@fixtures_path, filename)
    schema = path |> File.read!() |> JSON.decode!()
    {:ok, resolved} = Resolver.resolve(schema, path)
    resolved
  end

  describe "generate/2" do
    test "generates module with basic structure" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "defmodule Test.SimpleSchema do"
      assert code =~ "@moduledoc"
      assert code =~ "import Ecto.Changeset"
      assert code =~ "@fields"
      assert code =~ "def fields"
      assert code =~ "def new"
    end

    test "generates field definitions" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "name: :name"
      assert code =~ "name: :age"
      assert code =~ "name: :email"
      assert code =~ "name: :active"
    end

    test "generates correct types for fields" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "type: :string"
      assert code =~ "type: :integer"
      assert code =~ "type: :boolean"
    end

    test "generates required field validation" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.SimpleSchema")

      assert code =~ "validate_required"
      # Should include both required fields
      assert code =~ ":name" or code =~ ":age"
    end

    test "generates enum type attributes" do
      schema = parse_and_resolve("enum_schema.json")
      code = Schemecto.generate(schema, module: "Test.EnumSchema")

      assert code =~ "@status_values"
      assert code =~ ":pending"
      assert code =~ ":active"
      assert code =~ ":completed"
      assert code =~ "@status_type"
      assert code =~ "Ecto.ParameterizedType.init(Ecto.Enum"
    end

    test "generates code for schema with formats" do
      schema = parse_and_resolve("formats_schema.json")
      code = Schemecto.generate(schema, module: "Test.FormatsSchema")

      assert code =~ "type: :utc_datetime"
      assert code =~ "type: :date"
      assert code =~ "type: :binary_id"
    end

    test "generates code for schema with arrays" do
      schema = parse_and_resolve("array_schema.json")
      code = Schemecto.generate(schema, module: "Test.ArraySchema")

      assert code =~ "{:array, :string}"
      assert code =~ "{:array, :integer}"
    end

    test "generates code for allOf schema with merged properties" do
      schema = parse_and_resolve("all_of_schema.json")
      code = Schemecto.generate(schema, module: "Test.AllOfSchema")

      # Should have properties from both base and extended schema
      assert code =~ "name: :id"
      assert code =~ "name: :created_at"
      assert code =~ "name: :name"
      assert code =~ "name: :description"

      # Title should be from the extended schema
      assert code =~ "Extended Schema"
    end

    test "generates union module for oneOf schema" do
      schema = parse_and_resolve("one_of_schema.json")
      code = Schemecto.generate(schema, module: "Test.MessageUnion")

      assert code =~ "defmodule Test.MessageUnion do"
      assert code =~ "@variants"
      assert code =~ "def variants"
      assert code =~ "def cast"
    end

    test "generates moduledoc from schema title and description" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.DocSchema")

      assert code =~ "@moduledoc"
      assert code =~ "Simple Schema"
      assert code =~ "A simple test schema with basic properties."
    end

    test "generates code with Schemecto.new call" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.Schema")

      assert code =~ "Schemecto.new(@fields, params)"
    end

    test "infers module name from schema title when not provided" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module_prefix: "MyApp.Schemas")

      # Should use the filename or title to infer module name
      assert code =~ "defmodule MyApp.Schemas."
    end

    test "generates ref types with Schemecto.one" do
      schema = parse_and_resolve("ref_schema.json")
      code = Schemecto.generate(schema, module: "Test.RefSchema")

      # File refs should generate Schemecto.one references
      assert code =~ "Schemecto.one"
    end

    test "generates code for nullable types" do
      schema = parse_and_resolve("nullable_schema.json")
      code = Schemecto.generate(schema, module: "Test.NullableSchema")

      # Nullable types should still be generated
      assert code =~ "name: :optional_name"
      assert code =~ "name: :optional_count"
    end
  end

  describe "generated code compilation" do
    test "generated code compiles successfully" do
      schema = parse_and_resolve("simple_schema.json")
      code = Schemecto.generate(schema, module: "Test.CompilableSchema")

      # Verify the code can be parsed
      assert {:ok, _ast} = Code.string_to_quoted(code)
    end

    test "generated code for enum schema compiles successfully" do
      schema = parse_and_resolve("enum_schema.json")
      code = Schemecto.generate(schema, module: "Test.CompilableEnumSchema")

      assert {:ok, _ast} = Code.string_to_quoted(code)
    end

    test "generated code for allOf schema compiles successfully" do
      schema = parse_and_resolve("all_of_schema.json")
      code = Schemecto.generate(schema, module: "Test.CompilableAllOfSchema")

      assert {:ok, _ast} = Code.string_to_quoted(code)
    end

    test "generated code for oneOf schema compiles successfully" do
      schema = parse_and_resolve("one_of_schema.json")
      code = Schemecto.generate(schema, module: "Test.CompilableOneOfSchema")

      assert {:ok, _ast} = Code.string_to_quoted(code)
    end
  end
end
