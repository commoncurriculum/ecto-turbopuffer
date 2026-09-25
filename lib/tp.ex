defmodule TP do
  @moduledoc """
  Ecto type for turbopuffer attributes: the turbopuffer counterpart of `Ch`.

      defmodule MyApp.Search.CardStack do
        use Ecto.Schema
        use TP, distance_metric: :cosine_distance

        @primary_key {:id, TP, type: "string", autogenerate: false}
        schema "card_stacks" do
          field :title, TP, type: "string", full_text_search: true
          field :markdown, TP, type: "string", full_text_search: [stemming: true], embed: "openai/text-embedding-3-small"
          field :standard_ids, TP, type: "[]string"
          field :updated_at, TP, type: "datetime"
        end
      end

  `type:` takes turbopuffer's type strings and every other option is a turbopuffer schema option (see
  `TP.Attribute`), validated at compile time.

  Every schema with `TP` fields needs `use TP`, before `schema`. It checks the whole namespace when the schema
  compiles (see `TP.Namespace`) and takes these options:

    * `:distance_metric` - `:cosine_distance` or `:euclidean_squared`, required when the namespace has vector
      columns, including the ones native embedding computes. turbopuffer applies it to every vector column.
    * `:num_shards` - partitions the namespace across 1 to 256 shards, to grow past one index's size limit. It's
      fixed when the namespace is created, so changing it later makes writes fail. See `docs/turbopuffer/sharding.md`.

  Casting is lenient the way Ecto's own types are: `"7"` casts to an int, and a date to a datetime at midnight UTC.
  Dumping only encodes values that already fit the type. turbopuffer stores datetimes at millisecond precision, so
  `TP` truncates them to milliseconds.
  """
  use Ecto.ParameterizedType

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  @uint_max 18_446_744_073_709_551_615
  @f16_max 65_504.0
  @f32_max 3.4028234663852886e38

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @tp_options TP.__options__!(opts)
      @tp_distance_metric @tp_options.distance_metric
      @after_compile TP

      @doc false
      def __tp__(:distance_metric), do: @tp_options.distance_metric
      def __tp__(:num_shards), do: @tp_options.num_shards
    end
  end

  @doc false
  def __options__!(opts) do
    opts = Keyword.validate!(opts, [:distance_metric, :num_shards])

    distance_metric =
      case opts[:distance_metric] do
        nil ->
          nil

        metric when metric in [:cosine_distance, :euclidean_squared] ->
          Atom.to_string(metric)

        other ->
          raise ArgumentError,
                ":distance_metric must be :cosine_distance or :euclidean_squared, got: #{inspect(other)}"
      end

    num_shards =
      case opts[:num_shards] do
        shards when is_nil(shards) or (is_integer(shards) and shards in 1..256) -> shards
        other -> raise ArgumentError, ":num_shards must be an integer from 1 to 256, got: #{inspect(other)}"
      end

    %{distance_metric: distance_metric, num_shards: num_shards}
  end

  @doc false
  def __after_compile__(env, _bytecode), do: TP.Namespace.validate!(env.module)

  # ------------------------------------------------------------------------------------------------
  # Ecto.ParameterizedType
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.ParameterizedType
  def init(opts) do
    schema = opts[:schema]

    if schema && Module.open?(schema) && not Module.has_attribute?(schema, :tp_distance_metric) do
      raise ArgumentError,
            "#{inspect(schema)} has TP fields, so it needs `use TP` before `schema`, which checks the namespace " <>
              "and sets its distance metric"
    end

    TP.Attribute.new(opts)
  end

  @impl Ecto.ParameterizedType
  def type(%{type: type}), do: ecto_type(type)

  @impl Ecto.ParameterizedType
  def cast(value, %{type: type}), do: cast_value(value, type)

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _attribute), do: {:ok, nil}
  def dump(value, _dumper, %{type: type}), do: encode(value, type)

  @impl Ecto.ParameterizedType
  def load(value, _loader, %{type: type}), do: load_value(value, type)

  @impl Ecto.ParameterizedType
  def autogenerate(%{type: :uuid}), do: Ecto.UUID.generate()

  @impl Ecto.ParameterizedType
  def embed_as(_format, _attribute), do: :dump

  @impl Ecto.ParameterizedType
  def format(%{type: type}), do: "#TP<#{TP.Types.encode(type)}>"

  # ------------------------------------------------------------------------------------------------
  # PRIVATE
  # ------------------------------------------------------------------------------------------------

  defp ecto_type(:string), do: :string
  defp ecto_type(type) when type in [:int, :uint], do: :integer
  defp ecto_type(:float), do: :float
  defp ecto_type(:bool), do: :boolean
  defp ecto_type(:uuid), do: Ecto.UUID
  defp ecto_type(:datetime), do: :utc_datetime_usec
  defp ecto_type(:bytes), do: :binary
  defp ecto_type({:array, element}), do: {:array, ecto_type(element)}
  defp ecto_type({:vector, _dims, :i8}), do: {:array, :integer}
  defp ecto_type({:vector, _dims, _element}), do: {:array, :float}
  defp ecto_type({:multi_vector, _dims, _element}), do: {:array, {:array, :float}}
  defp ecto_type({:sparse_vector, _element}), do: {:map, :float}

  defp cast_value(nil, _type), do: {:ok, nil}
  defp cast_value(value, :string), do: Ecto.Type.cast(:string, value)
  defp cast_value(value, :int), do: cast_integer(value, @int_min, @int_max)
  defp cast_value(value, :uint), do: cast_integer(value, 0, @uint_max)
  defp cast_value(value, :float), do: Ecto.Type.cast(:float, value)
  defp cast_value(value, :bool), do: Ecto.Type.cast(:boolean, value)
  defp cast_value(value, :uuid), do: Ecto.UUID.cast(value)

  defp cast_value(value, :datetime) do
    with {:ok, datetime} <- cast_datetime(value), do: {:ok, DateTime.truncate(datetime, :millisecond)}
  end

  defp cast_value(value, :bytes) when is_binary(value), do: {:ok, value}
  defp cast_value(values, {:array, element}) when is_list(values), do: map_ok(values, &cast_element(&1, element))
  defp cast_value(values, {:vector, _, _} = type) when is_list(values), do: vector(values, type)

  defp cast_value(vectors, {:multi_vector, dims, element}) when is_list(vectors) do
    map_ok(vectors, &vector(&1, {:vector, dims, element}))
  end

  defp cast_value(%{} = weights, {:sparse_vector, _}) when not is_struct(weights) do
    with {:ok, pairs} <- map_ok(Map.to_list(weights), &weight(&1, true)), do: {:ok, Map.new(pairs)}
  end

  defp cast_value(_value, _type), do: :error

  defp cast_element(nil, _element), do: :error
  defp cast_element(value, element), do: cast_value(value, element)

  defp cast_integer(value, min, max) do
    case Ecto.Type.cast(:integer, value) do
      {:ok, integer} when integer >= min and integer <= max -> {:ok, integer}
      _ -> :error
    end
  end

  defp cast_datetime(%Date{} = date), do: DateTime.new(date, ~T[00:00:00.000], "Etc/UTC")

  defp cast_datetime(value) when is_binary(value) do
    case Ecto.Type.cast(:utc_datetime_usec, value) do
      {:ok, datetime} ->
        {:ok, datetime}

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> cast_datetime(date)
          {:error, _} -> :error
        end
    end
  end

  defp cast_datetime(value), do: Ecto.Type.cast(:utc_datetime_usec, value)

  # A dense vector's elements as floats, or integers for i8, within the element type's range.
  defp vector(values, {:vector, dims, element}) when is_list(values) and length(values) == dims do
    max = if element == :f16, do: @f16_max, else: @f32_max

    map_ok(values, fn
      value when element == :i8 and is_integer(value) and value in -128..127 -> {:ok, value}
      value when element != :i8 and is_number(value) and abs(value) <= max -> {:ok, value / 1}
      _ -> :error
    end)
  end

  defp vector(_values, _type), do: :error

  # A sparse vector's {dimension, weight}. Casting also takes atom dimensions.
  defp weight({key, weight}, atom_keys?) when is_number(weight) and abs(weight) <= @f16_max do
    cond do
      is_binary(key) -> {:ok, {key, weight / 1}}
      atom_keys? and is_atom(key) and not is_nil(key) -> {:ok, {Atom.to_string(key), weight / 1}}
      true -> :error
    end
  end

  defp weight(_pair, _atom_keys?), do: :error

  defp map_ok(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp encode(string, :string) when is_binary(string), do: {:ok, string}
  defp encode(int, :int) when is_integer(int) and int >= @int_min and int <= @int_max, do: {:ok, int}
  defp encode(uint, :uint) when is_integer(uint) and uint >= 0 and uint <= @uint_max, do: {:ok, uint}
  defp encode(float, :float) when is_number(float), do: {:ok, float / 1}
  defp encode(bool, :bool) when is_boolean(bool), do: {:ok, bool}

  # Ecto.UUID.cast also takes 16 raw bytes, which aren't a uuid string.
  defp encode(uuid, :uuid) when is_binary(uuid) and byte_size(uuid) == 36, do: Ecto.UUID.cast(uuid)

  defp encode(%DateTime{time_zone: "Etc/UTC"} = datetime, :datetime) do
    {:ok, datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()}
  end

  defp encode(bytes, :bytes) when is_binary(bytes), do: {:ok, Base.encode64(bytes)}

  defp encode(values, {:array, element}) when is_list(values) do
    map_ok(values, fn
      nil -> :error
      value -> encode(value, element)
    end)
  end

  # turbopuffer's compact vector encoding is base64 little-endian f32, whatever the schema's element type.
  defp encode(values, {:vector, _, _} = type) do
    with {:ok, vector} <- vector(values, type) do
      {:ok, Base.encode64(for value <- vector, into: <<>>, do: <<value::float-32-little>>)}
    end
  end

  defp encode(vectors, {:multi_vector, dims, element}) when is_list(vectors) do
    map_ok(vectors, &vector(&1, {:vector, dims, element}))
  end

  defp encode(%{} = weights, {:sparse_vector, _}) when not is_struct(weights) do
    with {:ok, pairs} <- map_ok(Map.to_list(weights), &weight(&1, false)), do: {:ok, Map.new(pairs)}
  end

  defp encode(_value, _type), do: :error

  defp load_value(base64, :bytes) when is_binary(base64), do: Base.decode64(base64)

  # query.md says base64 vectors in responses are little-endian f32, like writes, but turbopuffer sends each
  # attribute's own element type: 2 bytes per f16 and 1 per i8.
  defp load_value(base64, {:vector, dims, element} = type) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, binary} when byte_size(binary) == dims * 4 and element == :f32 ->
        vector(for(<<value::float-32-little <- binary>>, do: value), type)

      {:ok, binary} when byte_size(binary) == dims * 2 and element == :f16 ->
        vector(for(<<value::float-16-little <- binary>>, do: value), type)

      {:ok, binary} when byte_size(binary) == dims and element == :i8 ->
        vector(for(<<value::signed-8 <- binary>>, do: value), type)

      _ ->
        :error
    end
  end

  defp load_value(values, {:vector, _dims, :i8} = type) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_float(value) and value == trunc(value) -> trunc(value)
      value -> value
    end)
    |> vector(type)
  end

  defp load_value(vectors, {:multi_vector, dims, element}) when is_list(vectors) do
    map_ok(vectors, &load_value(&1, {:vector, dims, element}))
  end

  defp load_value(value, type), do: cast_value(value, type)
end
