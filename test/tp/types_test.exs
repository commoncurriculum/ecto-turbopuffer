defmodule TP.TypesTest do
  use ExUnit.Case, async: true

  @types %{
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
    "[1536]f32" => {:vector, 1536, :f32},
    "[512]f16" => {:vector, 512, :f16},
    "[512]i8" => {:vector, 512, :i8},
    "[][128]f32" => {:multi_vector, 128, :f32},
    "{}f16" => {:sparse_vector, :f16}
  }

  test "decodes and encodes every turbopuffer type" do
    for {string, decoded} <- @types do
      assert TP.Types.decode(string) == decoded
      assert TP.Types.encode(decoded) == string
    end
  end

  test "accepts vectors up to turbopuffer's dimension limit" do
    assert TP.Types.decode("[1]f32") == {:vector, 1, :f32}
    assert TP.Types.decode("[10752]f32") == {:vector, 10_752, :f32}
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
  end

  test "rejects non-string types" do
    assert_raise ArgumentError, ~r/must be a string/, fn -> TP.Types.decode(:string) end
  end

  test "filterable?/1 is every scalar but bytes, and arrays" do
    filterable = ~w(string int uint float uuid datetime bool []string []int []uint []float []uuid []datetime []bool)

    for {string, type} <- @types do
      assert TP.Types.filterable?(type) == string in filterable, string
    end
  end

  test "vector?/1 is dense vectors and multi-vectors" do
    for {string, type} <- @types do
      assert TP.Types.vector?(type) == string in ~w([1536]f32 [512]f16 [512]i8 [][128]f32), string
    end
  end
end
