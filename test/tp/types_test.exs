defmodule TP.TypesTest do
  # turbopuffer's type strings. The live types_test.exs checks turbopuffer stores each one TP declares.
  use ExUnit.Case, async: true

  test "decodes and encodes every turbopuffer type" do
    for {string, decoded} <- %{
          "string" => :string,
          "int" => :int,
          "uint" => :uint,
          "float" => :float,
          "uuid" => :uuid,
          "datetime" => :datetime,
          "bool" => :bool,
          "bytes" => :bytes,
          "[]string" => {:array, :string},
          "[]int" => {:array, :int},
          "[]uint" => {:array, :uint},
          "[]float" => {:array, :float},
          "[]uuid" => {:array, :uuid},
          "[]datetime" => {:array, :datetime},
          "[]bool" => {:array, :bool},
          "[1]f32" => {:vector, 1, :f32},
          "[10752]f32" => {:vector, 10_752, :f32},
          "[512]f16" => {:vector, 512, :f16},
          "[512]i8" => {:vector, 512, :i8},
          "[][128]f32" => {:multi_vector, 128, :f32},
          "{}f16" => {:sparse_vector, :f16}
        } do
      assert TP.Types.decode(string) == decoded
      assert TP.Types.encode(decoded) == string
    end
  end

  test "rejects types turbopuffer doesn't have" do
    for type <- [
          "text",
          "String",
          "[]bytes",
          "[]",
          "[]{}f16",
          "[0]f32",
          "[10753]f32",
          "[-1]f32",
          "[abc]f32",
          "[512]f64",
          "[512]",
          "[][128]f16",
          "[][128]i8",
          "{}f32",
          ""
        ] do
      assert_raise ArgumentError, ~r/failed to decode .* as turbopuffer type/, fn -> TP.Types.decode(type) end
    end

    assert_raise ArgumentError, ~r/must be a string/, fn -> TP.Types.decode(:string) end
  end
end
