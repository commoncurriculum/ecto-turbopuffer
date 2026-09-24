defmodule TP.Types do
  @moduledoc """
  Decodes and encodes turbopuffer attribute type strings, the way `Ch.Types` does for ClickHouse.

      "string"     <-> :string
      "[]uuid"     <-> {:array, :uuid}
      "[512]f16"   <-> {:vector, 512, :f16}
      "[][128]f32" <-> {:multi_vector, 128, :f32}
      "{}f16"      <-> {:sparse_vector, :f16}

  See https://turbopuffer.com/docs/write#schema for the list of types.
  """

  @scalars [:string, :int, :uint, :float, :uuid, :datetime, :bool, :bytes]
  @array_elements [:string, :int, :uint, :float, :uuid, :datetime, :bool]
  @max_vector_dims 10_752

  @type array_element :: :string | :int | :uint | :float | :uuid | :datetime | :bool
  @type t ::
          array_element()
          | :bytes
          | {:array, array_element()}
          | {:vector, pos_integer(), :f32 | :f16 | :i8}
          | {:multi_vector, pos_integer(), :f32}
          | {:sparse_vector, :f16}

  @spec decode(String.t()) :: t()
  def decode(type) when is_binary(type) do
    case do_decode(type) do
      {:ok, decoded} ->
        decoded

      {:error, reason} ->
        raise ArgumentError,
              "failed to decode #{inspect(type)} as turbopuffer type (#{reason}). " <>
                "Valid types: string, int, uint, float, uuid, datetime, bool, bytes, []string, []int, []uint, " <>
                "[]float, []uuid, []datetime, []bool, [N]f32, [N]f16, [N]i8, [][N]f32, {}f16"
    end
  end

  def decode(type), do: raise(ArgumentError, "turbopuffer type must be a string, got: #{inspect(type)}")

  @spec encode(t()) :: String.t()
  def encode(scalar) when scalar in @scalars, do: Atom.to_string(scalar)
  def encode({:array, element}) when element in @array_elements, do: "[]" <> Atom.to_string(element)
  def encode({:vector, dims, element}), do: "[#{dims}]#{element}"
  def encode({:multi_vector, dims, element}), do: "[][#{dims}]#{element}"
  def encode({:sparse_vector, :f16}), do: "{}f16"

  defp do_decode("{}f16"), do: {:ok, {:sparse_vector, :f16}}

  defp do_decode("[][" <> rest) do
    with {:ok, dims, element} <- decode_vector(rest) do
      if element == :f32,
        do: {:ok, {:multi_vector, dims, element}},
        else: {:error, "multi-vector attributes only support f32 elements"}
    end
  end

  defp do_decode("[]" <> element) do
    case scalar(element) do
      {:ok, atom} when atom in @array_elements -> {:ok, {:array, atom}}
      {:ok, atom} -> {:error, "#{atom} has no array variant"}
      :error -> {:error, "unknown array element type #{inspect(element)}"}
    end
  end

  defp do_decode("[" <> rest) do
    with {:ok, dims, element} <- decode_vector(rest), do: {:ok, {:vector, dims, element}}
  end

  defp do_decode(type) do
    case scalar(type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "unknown type"}
    end
  end

  defp decode_vector(rest) do
    with {dims, "]" <> element} <- Integer.parse(rest),
         true <- dims in 1..@max_vector_dims,
         {:ok, element} <- vector_element(element) do
      {:ok, dims, element}
    else
      false -> {:error, "vector dimensions must be between 1 and #{@max_vector_dims}"}
      {:error, _} = error -> error
      _ -> {:error, "expected a vector type like [512]f32"}
    end
  end

  defp vector_element("f32"), do: {:ok, :f32}
  defp vector_element("f16"), do: {:ok, :f16}
  defp vector_element("i8"), do: {:ok, :i8}
  defp vector_element(other), do: {:error, "unknown vector element type #{inspect(other)}"}

  for scalar <- @scalars do
    defp scalar(unquote(Atom.to_string(scalar))), do: {:ok, unquote(scalar)}
  end

  defp scalar(_), do: :error
end
