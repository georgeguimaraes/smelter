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

    test "maps array with union ref items to array of map" do
      property = %{
        "type" => "array",
        "items" => %{:_ref_module => "Test.UnionModule", :_ref_type => :union}
      }

      assert {{:array, :map}, _opts} = TypeMapper.map_type(property)
    end

    test "maps union ref type to :union_ref" do
      property = %{:_ref_module => "Test.UnionModule", :_ref_type => :union}
      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :union_ref
      assert opts[:module] == "Test.UnionModule"
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

    test "maps oneOf composition to union type" do
      property = %{
        :_composition =>
          {:one_of, [%{:_ref_module => "Test.VariantA"}, %{:_ref_module => "Test.VariantB"}]}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :union
      assert opts[:strategy] == :one_of
      assert length(opts[:variants]) == 2
    end

    test "maps anyOf composition to union type" do
      property = %{
        :_composition =>
          {:any_of, [%{:_ref_module => "Test.VariantA"}, %{:_ref_module => "Test.VariantB"}]}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :union
      assert opts[:strategy] == :any_of
    end

    test "maps allOf composition with properties to embedded" do
      property = %{
        :_composition => {:all_of, []},
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :embedded
      assert is_list(opts[:fields])
    end

    test "maps allOf composition without properties to map" do
      property = %{:_composition => {:all_of, []}}
      assert {type, _opts} = TypeMapper.map_type(property)
      assert type == :map
    end

    test "maps nested object with properties to embedded" do
      property = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :embedded
      fields = opts[:fields]
      assert length(fields) == 2

      name_field = Enum.find(fields, &(&1.name == "name"))
      assert name_field.type == :string
      assert name_field.required == true

      age_field = Enum.find(fields, &(&1.name == "age"))
      assert age_field.type == :integer
      assert age_field.required == false
    end

    test "maps object with additionalProperties ref" do
      property = %{
        "type" => "object",
        "additionalProperties" => %{:_ref_module => "Test.Value"}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :map
      assert opts[:value_type] == {:ref, "Test.Value"}
    end

    test "maps object with additionalProperties type" do
      property = %{
        "type" => "object",
        "additionalProperties" => %{"type" => "string"}
      }

      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :map
      assert opts[:value_type] == :string
    end

    test "maps array without items to array of map" do
      property = %{"type" => "array"}
      assert {{:array, :map}, _opts} = TypeMapper.map_type(property)
    end

    test "maps string with format time" do
      assert {type, _opts} = TypeMapper.map_type(%{"type" => "string", "format" => "time"})
      assert type == :time
    end

    test "maps string with format ipv4" do
      assert {type, opts} = TypeMapper.map_type(%{"type" => "string", "format" => "ipv4"})
      assert type == :string
      assert opts[:format] == :ipv4
    end

    test "maps nullable with multiple non-null types to map" do
      property = %{"type" => ["string", "integer", "null"]}
      assert {type, opts} = TypeMapper.map_type(property)
      assert type == :map
      assert opts[:nullable] == true
    end

    test "extracts exclusive min/max constraints" do
      assert {_type, opts} =
               TypeMapper.map_type(%{
                 "type" => "integer",
                 "exclusiveMinimum" => 0,
                 "exclusiveMaximum" => 100
               })

      assert opts[:exclusive_minimum] == 0
      assert opts[:exclusive_maximum] == 100
    end
  end
end
