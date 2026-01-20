defmodule Smelter.TypeMapperTest do
  use ExUnit.Case, async: true

  alias Smelter.TypeMapper

  describe "map_type/1" do
    test "maps string type" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "string"})
      assert type == :string
    end

    test "maps integer type" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "integer"})
      assert type == :integer
    end

    test "maps number type to float" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "number"})
      assert type == :float
    end

    test "maps boolean type" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "boolean"})
      assert type == :boolean
    end

    test "maps object type to map" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "object"})
      assert type == :map
    end

    test "maps string with format date-time" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "string", "format" => "date-time"})
      assert type == :utc_datetime
    end

    test "maps string with format date" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "string", "format" => "date"})
      assert type == :date
    end

    test "maps string with format email" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => "string", "format" => "email"})
      assert type == :string
      assert opts[:format] == :email
    end

    test "maps string with format uri" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => "string", "format" => "uri"})
      assert type == :string
      assert opts[:format] == :uri
    end

    test "maps string with format uuid" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "string", "format" => "uuid"})
      assert type == :binary_id
    end

    test "maps enum type" do
      assert {type, opts} =
               TypeMapper.map_type(%{"type" => "string", "enum" => ["a", "b", "c"]})

      assert type == :enum
      assert opts[:values] == ["a", "b", "c"]
    end

    test "maps const type" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => "string", "const" => "fixed"})
      assert type == :const
      assert opts[:value] == "fixed"
    end

    test "maps array of strings" do
      assert {type, opts} =
               TypeMapper.map_type(%{"type" => "array", "items" => %{"type" => "string"}})

      assert type == :array_of
      assert opts[:inner_type] == :string
    end

    test "maps array of integers" do
      assert {type, opts} =
               TypeMapper.map_type(%{"type" => "array", "items" => %{"type" => "integer"}})

      assert type == :array_of
      assert opts[:inner_type] == :integer
    end

    test "maps nullable string type" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => ["string", "null"]})
      assert type == :string
      assert opts[:nullable] == true
    end

    test "maps nullable integer type" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => ["integer", "null"]})
      assert type == :integer
      assert opts[:nullable] == true
    end

    test "maps ref type" do
      property = %{:_ref_module => "Test.Module"}
      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :ref
      assert opts[:module] == "Test.Module"
      assert opts[:cardinality] == :one
    end

    test "maps array with ref items" do
      property = %{
        "type" => "array",
        "items" => %{:_ref_module => "Test.Module"}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :ref
      assert opts[:module] == "Test.Module"
      assert opts[:cardinality] == :many
    end

    test "extracts constraints from property" do
      assert {_type, opts} =
               TypeMapper.map_type(%{
                 "type" => "integer",
                 "minimum" => 0,
                 "maximum" => 100
               })

      assert opts[:minimum] == 0
      assert opts[:maximum] == 100
    end

    test "extracts string constraints" do
      assert {_type, opts} =
               TypeMapper.map_type(%{
                 "type" => "string",
                 "minLength" => 1,
                 "maxLength" => 255,
                 "pattern" => "^[a-z]+$"
               })

      assert opts[:min_length] == 1
      assert opts[:max_length] == 255
      assert opts[:pattern] == "^[a-z]+$"
    end

    test "extracts default value" do
      assert {_type, opts} = TypeMapper.map_type(%{"type" => "boolean", "default" => true})
      assert opts[:default] == true
    end
  end

  describe "to_ecto_type/1" do
    test "converts primitive types" do
      assert TypeMapper.to_ecto_type({:string, []}) == ":string"
      assert TypeMapper.to_ecto_type({:integer, []}) == ":integer"
      assert TypeMapper.to_ecto_type({:float, []}) == ":float"
      assert TypeMapper.to_ecto_type({:boolean, []}) == ":boolean"
      assert TypeMapper.to_ecto_type({:map, []}) == ":map"
    end

    test "converts datetime types" do
      assert TypeMapper.to_ecto_type({:utc_datetime, []}) == ":utc_datetime"
      assert TypeMapper.to_ecto_type({:date, []}) == ":date"
      assert TypeMapper.to_ecto_type({:time, []}) == ":time"
    end

    test "converts array types" do
      assert TypeMapper.to_ecto_type({:array_of, [inner_type: :string]}) == "{:array, :string}"
      assert TypeMapper.to_ecto_type({:array_of, [inner_type: :integer]}) == "{:array, :integer}"
    end

    test "converts enum type" do
      result = TypeMapper.to_ecto_type({:enum, [values: ["a", "b"]]})
      assert result =~ "Ecto.ParameterizedType.init(Ecto.Enum"
      assert result =~ ":a"
      assert result =~ ":b"
    end

    test "converts ref type" do
      result = TypeMapper.to_ecto_type({:ref, [module: "Test.Schema", cardinality: :one]})
      assert result =~ "Schemecto.one"
      assert result =~ "Test.Schema"
    end

    test "converts ref type with many cardinality" do
      result = TypeMapper.to_ecto_type({:ref, [module: "Test.Schema", cardinality: :many]})
      assert result =~ "Schemecto.many"
      assert result =~ "Test.Schema"
    end
  end

  describe "to_type_ast/1" do
    test "returns atoms for primitive types" do
      assert TypeMapper.to_type_ast({:string, []}) == :string
      assert TypeMapper.to_type_ast({:integer, []}) == :integer
      assert TypeMapper.to_type_ast({:boolean, []}) == :boolean
      assert TypeMapper.to_type_ast({:map, []}) == :map
    end

    test "returns tuples for array types" do
      assert TypeMapper.to_type_ast({:array_of, [inner_type: :string]}) == {:array, :string}
      assert TypeMapper.to_type_ast({:array_of, [inner_type: :integer]}) == {:array, :integer}
    end

    test "returns AST for ref types" do
      ast = TypeMapper.to_type_ast({:ref, [module: "Test.Schema", cardinality: :one]})
      code = Macro.to_string(ast)
      assert code =~ "Schemecto.one"
      assert code =~ "Test.Schema"
    end
  end
end
