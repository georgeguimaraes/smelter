defmodule Smelter.NonObjectRefTest do
  # $ref targets whose root is an array or a scalar rather than an object.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp write_schemas!(dir, schemas) do
    Enum.each(schemas, fn {name, schema} ->
      File.write!(Path.join(dir, name), JSON.encode!(schema))
    end)
  end

  defp compile!(dir, name, module) do
    {:ok, code} =
      Smelter.compile(Path.join(dir, name),
        module: module,
        module_prefix: "Test",
        schemas_dir: dir
      )

    code
  end

  describe "$ref to an array schema" do
    setup %{tmp_dir: dir} do
      write_schemas!(dir, %{
        "checkout.json" => %{
          "type" => "object",
          "properties" => %{
            "totals" => %{"$ref" => "totals.json", "description" => "Cart totals."}
          },
          "required" => ["totals"]
        },
        "totals.json" => %{
          "title" => "Totals",
          "description" => "One subtotal and one total.",
          "type" => "array",
          "items" => %{
            "allOf" => [
              %{"$ref" => "total.json"},
              %{
                "type" => "object",
                "properties" => %{
                  "lines" => %{"type" => "array", "items" => %{"type" => "object"}}
                }
              }
            ]
          },
          "allOf" => [
            %{"contains" => %{"properties" => %{"type" => %{"const" => "total"}}}}
          ]
        },
        "total.json" => %{
          "title" => "Total",
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string"},
            "amount" => %{"$ref" => "amount.json"}
          },
          "allOf" => [
            %{
              "if" => %{"properties" => %{"type" => %{"const" => "discount"}}},
              "then" => %{"properties" => %{"amount" => %{"exclusiveMaximum" => 0}}}
            }
          ],
          "required" => ["type", "amount"]
        },
        "amount.json" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
      })

      :ok
    end

    test "the parent embeds many of the array's module", %{tmp_dir: dir} do
      code = compile!(dir, "checkout.json", "Test.Checkout")

      assert code =~ "alias Test.Totals"
      assert code =~ "embeds_many(:totals, Totals)"
      assert code =~ "cast_embed(:totals, required: true)"
    end

    test "the array's module is built from its allOf-composed items", %{tmp_dir: dir} do
      code = compile!(dir, "totals.json", "Test.Totals")

      assert code =~ "Totals\n\n  One subtotal and one total."
      assert code =~ "field(:amount, :integer)"
      assert code =~ "field(:lines, {:array, :map})"
      assert code =~ "field(:type, :string)"
      assert code =~ "validate_required([:type, :amount])"
    end

    test "scalar refs next to an allOf resolve to their type", %{tmp_dir: dir} do
      code = compile!(dir, "total.json", "Test.Total")

      assert code =~ "field(:amount, :integer)"
      refute code =~ ":map"
    end
  end

  describe "$ref to a scalar schema" do
    test "keeps the target's type, enum and constraints", %{tmp_dir: dir} do
      write_schemas!(dir, %{
        "order.json" => %{
          "type" => "object",
          "properties" => %{
            "amount" => %{"$ref" => "amount.json"},
            "status" => %{"$ref" => "status.json"},
            "paid" => %{"$ref" => "#/$defs/flag"}
          },
          "$defs" => %{"flag" => %{"type" => "boolean"}}
        },
        "amount.json" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
        "status.json" => %{"type" => "string", "enum" => ["open", "closed"]}
      })

      {:ok, resolved} = Smelter.parse(Path.join(dir, "order.json"), schemas_dir: dir)
      assert resolved["properties"]["amount"]["minimum"] == 0
      assert resolved["properties"]["amount"]["maximum"] == 100

      code = Smelter.generate(resolved, module: "Test.Order")
      assert code =~ "field(:amount, :integer)"
      assert code =~ "field(:paid, :boolean)"
      assert code =~ "@status_values [:open, :closed]"
      assert code =~ "field(:status, Ecto.Enum, values: @status_values)"
    end
  end

  describe "$ref to arrays without an item module" do
    test "arrays of scalars and of arrays become plain array fields", %{tmp_dir: dir} do
      write_schemas!(dir, %{
        "product.json" => %{
          "type" => "object",
          "properties" => %{
            "tags" => %{"$ref" => "tags.json"},
            "sizes" => %{"$ref" => "#/$defs/sizes"},
            "matrix" => %{"$ref" => "matrix.json"}
          },
          "$defs" => %{
            "sizes" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => ["s", "m"]}
            }
          }
        },
        "tags.json" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "allOf" => [%{"minItems" => 1}]
        },
        "matrix.json" => %{
          "type" => "array",
          "items" => %{"type" => "array", "items" => %{"type" => "integer"}}
        }
      })

      code = compile!(dir, "product.json", "Test.Product")

      assert code =~ "field(:tags, {:array, :string})"
      assert code =~ "field(:sizes, {:array, :string})"
      assert code =~ "field(:matrix, {:array, :map})"
      refute code =~ "embeds_"
    end

    test "an array whose items are a $ref embeds many of that module", %{tmp_dir: dir} do
      write_schemas!(dir, %{
        "cart.json" => %{
          "type" => "object",
          "properties" => %{"items" => %{"$ref" => "items.json"}}
        },
        "items.json" => %{"type" => "array", "items" => %{"$ref" => "item.json"}},
        "item.json" => %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
      })

      code = compile!(dir, "cart.json", "Test.Cart")

      assert code =~ "embeds_many(:items, Item)"
      refute code =~ "Items"
    end
  end
end
