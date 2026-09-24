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

  `type:` takes turbopuffer's type strings and every other option is a turbopuffer schema option
  (see `TP.Attribute`), validated at compile time.

  `use TP` sets namespace-level options and checks the whole namespace at compile time:

    * `:distance_metric` - `:cosine_distance` or `:euclidean_squared`. turbopuffer needs one on every write to a
      namespace with vector columns, including the ones native embedding computes. A vector's
      `ann: [distance_metric: ...]` also sets it, and the two can't disagree.

  The rest of the API:

    * `TP.schema/1` renders the namespace schema to send with writes, after checking turbopuffer's namespace-wide
      rules: a valid namespace name, one `id` primary key, 1,024 attributes, 8 vector columns (embedded attributes'
      computed vectors count), 4 embedded attributes, and one distance metric, which namespaces with vector columns
      must declare.
    * `TP.distance_metric/1` is that distance metric, for the write's `distance_metric`.
    * `TP.attributes/1` lists the schema's fields as `TP.Attribute`s.
    * `TP.dump/1` turns a struct into an `upsert_rows` row and `TP.dump_attribute/3` encodes a single value, such as
      a filter operand. Both enforce turbopuffer's value limits: 64-byte ids, 4 KiB filterable values, 8 MiB values,
      and 1,024 sparse dimensions.
    * `TP.load/2` turns a query row back into the struct.

  turbopuffer stores datetimes at millisecond precision, so `TP` casts them to milliseconds.
  """
  use Ecto.ParameterizedType

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  @uint_max 18_446_744_073_709_551_615
  @f16_max 65_504.0
  @f32_max 3.4028234663852886e38

  @max_attributes 1_024
  @max_vector_columns 8
  @max_embedded_attributes 4
  @max_id_bytes 64
  @max_filterable_value_bytes 4_096
  @max_value_bytes 8 * 1024 * 1024
  @max_sparse_dims 1_024

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @tp_distance_metric TP.__distance_metric_option__!(opts, __MODULE__)
      @after_compile TP

      @doc false
      def __tp__(:distance_metric), do: @tp_distance_metric
    end
  end

  @doc false
  def __distance_metric_option__!(opts, module) do
    case Keyword.keys(opts) -- [:distance_metric] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown `use TP` option(s) #{inspect(unknown)} in #{inspect(module)}"
    end

    case opts[:distance_metric] do
      nil ->
        nil

      metric ->
        string = if is_atom(metric), do: Atom.to_string(metric), else: metric

        if string in TP.Attribute.distance_metrics() do
          string
        else
          raise ArgumentError,
                ":distance_metric must be one of #{Enum.join(TP.Attribute.distance_metrics(), ", ")}, " <>
                  "got: #{inspect(metric)} in #{inspect(module)}"
        end
    end
  end

  @doc false
  def __after_compile__(env, _bytecode), do: schema(env.module)

  @doc """
  The turbopuffer schema for an Ecto schema whose fields all use `TP`, keyed by attribute name.
  Raises if the schema breaks a namespace-wide limit.
  """
  @spec schema(module()) :: %{String.t() => map() | String.t()}
  def schema(module) do
    module
    |> attributes()
    |> validate_namespace!(module)
    |> Enum.flat_map(fn
      %{primary_key: false} = attribute -> [{attribute.name, attribute.schema_entry}]
      # turbopuffer infers string ids, so only uuid and uint ids need declaring.
      %{type: :string} -> []
      attribute -> [{attribute.name, TP.Types.encode(attribute.type)}]
    end)
    |> Map.new()
  end

  @doc """
  The namespace's distance metric, from `use TP` or a vector's `ann` options. `nil` when it has no vector columns.
  """
  @spec distance_metric(module()) :: String.t() | nil
  def distance_metric(module) do
    module |> attributes() |> validate_namespace!(module) |> resolve_distance_metric!(module)
  end

  @doc """
  Dumps a struct to a row for `upsert_rows`, keyed by attribute name. Raises if a value doesn't fit its type or
  turbopuffer's limits, or if the id or a vector is missing.
  """
  @spec dump(struct()) :: %{String.t() => term()}
  def dump(%module{} = struct) do
    attributes = attributes(module)

    attributes
    |> Map.new(fn attribute -> {attribute.name, dump!(Map.fetch!(struct, attribute.field), attribute, module)} end)
    |> complete_row!(attributes, module)
  end

  @doc false
  # Checks a row of values Ecto already dumped, keyed by source, the way `dump/1` checks a struct.
  def __row__(module, dumped) do
    dumped
    |> Map.new(fn {source, value} -> {to_string(source), value} end)
    |> complete_row!(attributes(module), module)
  end

  @doc """
  The attributes of a schema whose fields all use `TP`, in field order.
  """
  @spec attributes(module()) :: [TP.Attribute.t()]
  def attributes(module) do
    Enum.map(module.__schema__(:fields), fn field ->
      case module.__schema__(:type, field) do
        {:parameterized, {TP, attribute}} ->
          attribute

        other ->
          raise ArgumentError,
                "#{inspect(module)}.#{field} has type #{inspect(other)}, but every turbopuffer attribute must use " <>
                  "TP. turbopuffer has no nested attributes, so flatten embedded data into TP fields."
      end
    end)
  end

  @doc """
  Encodes one value for `module`'s `field` the way turbopuffer expects it, e.g. a filter operand.
  """
  @spec dump_attribute(module(), atom(), term()) :: term()
  def dump_attribute(module, field, value) do
    case Enum.find(attributes(module), &(&1.field == field)) do
      nil -> raise ArgumentError, "#{inspect(module)} has no field #{inspect(field)}"
      attribute -> dump!(value, attribute, module)
    end
  end

  @doc """
  Loads a row returned by a turbopuffer query into `module`'s struct. Attributes the row doesn't include stay `nil`,
  and attributes the schema doesn't declare (like `$dist`) are ignored.
  """
  @spec load(module(), %{String.t() => term()}) :: struct()
  def load(module, row) when is_map(row) do
    fields =
      Enum.map(attributes(module), fn attribute ->
        value = Map.get(row, attribute.name)

        case load_value(value, attribute.type) do
          {:ok, loaded} ->
            {attribute.field, loaded}

          _ ->
            raise ArgumentError,
                  "cannot load #{inspect(value, limit: 5, printable_limit: 100)} as turbopuffer " <>
                    "#{TP.Types.encode(attribute.type)} for field #{inspect(attribute.field)} in #{inspect(module)}"
        end
      end)

    struct(module, fields)
  end

  # ------------------------------------------------------------------------------------------------
  # Ecto.ParameterizedType
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.ParameterizedType
  def init(opts), do: TP.Attribute.new(opts)

  @impl Ecto.ParameterizedType
  def type(%{type: type}), do: ecto_type(type)

  @impl Ecto.ParameterizedType
  def cast(value, %{type: type}), do: cast_value(value, type)

  @impl Ecto.ParameterizedType
  def dump(value, _dumper, params) do
    case encode_attribute(value, params) do
      {:ok, dumped} -> {:ok, dumped}
      {:error, _reason} -> :error
    end
  end

  @impl Ecto.ParameterizedType
  def load(value, _loader, %{type: type}), do: load_value(value, type)

  @impl Ecto.ParameterizedType
  def autogenerate(%{type: :uuid}), do: Ecto.UUID.generate()

  def autogenerate(%{type: type}) do
    raise ArgumentError, "TP can only autogenerate uuid ids, not #{TP.Types.encode(type)}"
  end

  @impl Ecto.ParameterizedType
  def embed_as(_format, _params), do: :dump

  @impl Ecto.ParameterizedType
  def format(%{type: type}), do: "#TP<#{TP.Types.encode(type)}>"

  # ------------------------------------------------------------------------------------------------
  # PRIVATE
  # ------------------------------------------------------------------------------------------------

  defp validate_namespace!(attributes, module) do
    embedded = Enum.filter(attributes, &Map.has_key?(&1.schema_entry, "embed"))
    vector_columns = vector_column_count(attributes)

    namespace = module.__schema__(:source)

    cond do
      not String.match?(namespace, ~r/\A[A-Za-z0-9\-_.]{1,128}\z/) ->
        raise ArgumentError,
              "#{inspect(module)}'s namespace #{inspect(namespace)} must match turbopuffer's [A-Za-z0-9-_.]{1,128}"

      Enum.count(attributes, & &1.primary_key) != 1 ->
        raise ArgumentError,
              "#{inspect(module)} needs one TP primary key, " <>
                "e.g. `@primary_key {:id, TP, type: \"string\", autogenerate: false}`"

      length(attributes) > @max_attributes ->
        raise ArgumentError,
              "#{inspect(module)} has #{length(attributes)} attributes; turbopuffer allows #{@max_attributes}"

      vector_columns > @max_vector_columns ->
        raise ArgumentError,
              "#{inspect(module)} has #{vector_columns} vector columns, counting embedded attributes' computed " <>
                "vectors; turbopuffer allows #{@max_vector_columns}"

      length(embedded) > @max_embedded_attributes ->
        raise ArgumentError,
              "#{inspect(module)} embeds #{length(embedded)} attributes; turbopuffer allows #{@max_embedded_attributes}"

      true ->
        :ok
    end

    Enum.each(embedded, &validate_embed_target!(&1, attributes, module))
    resolve_distance_metric!(attributes, module)
    attributes
  end

  defp vector_column_count(attributes) do
    Enum.count(attributes, fn
      %{type: {:vector, _dims, _element}} -> true
      %{type: {:multi_vector, _dims, _element}} -> true
      %{schema_entry: %{"embed" => _}} = attribute -> embed_target(attribute) == nil
      _ -> false
    end)
  end

  defp resolve_distance_metric!(attributes, module) do
    declared = if function_exported?(module, :__tp__, 1), do: module.__tp__(:distance_metric)

    case Enum.uniq(List.wrap(declared) ++ ann_distance_metrics(attributes)) do
      [metric] ->
        metric

      [] ->
        if vector_column_count(attributes) > 0 do
          raise ArgumentError,
                "#{inspect(module)} has vector columns, so turbopuffer needs a distance metric: " <>
                  "add `use TP, distance_metric: :cosine_distance` (or :euclidean_squared)"
        end

        nil

      metrics ->
        raise ArgumentError,
              "#{inspect(module)} declares different distance metrics (#{Enum.join(metrics, ", ")}), " <>
                "but turbopuffer uses one per namespace"
    end
  end

  defp embed_target(%{schema_entry: %{"embed" => %{"attribute" => target}}}), do: target
  defp embed_target(_attribute), do: nil

  defp validate_embed_target!(attribute, attributes, module) do
    with target when is_binary(target) <- embed_target(attribute) do
      embed = attribute.schema_entry["embed"]
      where = "(field #{inspect(attribute.field)} in #{inspect(module)})"

      case Enum.find(attributes, &(&1.name == target)) do
        %{type: {:vector, dims, element}} ->
          if embed["dims"] not in [nil, dims] do
            raise ArgumentError, "embed dims #{embed["dims"]} don't match #{target}'s #{dims} dimensions #{where}"
          end

          if embed["dtype"] not in [nil, Atom.to_string(element)] do
            raise ArgumentError, "embed dtype #{embed["dtype"]} doesn't match #{target}'s #{element} elements #{where}"
          end

        _ ->
          raise ArgumentError, "embed attribute #{inspect(target)} must be an [N] vector field in the schema #{where}"
      end
    end
  end

  defp ann_distance_metrics(attributes) do
    attributes
    |> Enum.flat_map(fn
      %{schema_entry: %{"ann" => %{"distance_metric" => metric}}} -> [metric]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp complete_row!(row, attributes, module) do
    Enum.reduce(attributes, row, fn
      %{primary_key: true} = attribute, row ->
        if row[attribute.name] == nil do
          raise ArgumentError, "cannot dump #{inspect(module)} without an id: turbopuffer ids can't be null"
        end

        row

      %{type: {:vector, _, _}} = attribute, row ->
        if row[attribute.name] == nil do
          require_embedded_vector!(attribute, attributes, row, module)
          Map.delete(row, attribute.name)
        else
          row
        end

      _attribute, row ->
        row
    end)
  end

  # A vector that native embedding fills from a string attribute can be left out when that string is present.
  defp require_embedded_vector!(attribute, attributes, row, module) do
    unless Enum.any?(attributes, &(embed_target(&1) == attribute.name and row[&1.name] != nil)) do
      raise ArgumentError,
            "cannot dump #{inspect(module)} without #{inspect(attribute.field)}: " <>
              "turbopuffer upserts must include every vector attribute"
    end
  end

  defp dump!(value, attribute, module) do
    case encode_attribute(value, attribute) do
      {:ok, dumped} ->
        dumped

      {:error, reason} ->
        raise ArgumentError,
              "cannot dump #{inspect(value, limit: 5, printable_limit: 100)} as turbopuffer " <>
                "#{TP.Types.encode(attribute.type)} for field #{inspect(attribute.field)} in #{inspect(module)}" <>
                if(reason, do: ": #{reason}", else: "")
    end
  end

  defp encode_attribute(value, %{type: type} = attribute) do
    with {:ok, cast} <- cast_for_dump(value, type),
         :ok <- check_limits(cast, attribute) do
      {:ok, encode(cast, type)}
    end
  end

  defp cast_for_dump(value, type) do
    case cast_value(value, type) do
      {:ok, cast} -> {:ok, cast}
      _ -> {:error, nil}
    end
  end

  defp check_limits(nil, _attribute), do: :ok

  defp check_limits(id, %{primary_key: true}) when is_binary(id) and byte_size(id) > @max_id_bytes do
    {:error, "turbopuffer ids can be at most #{@max_id_bytes} bytes"}
  end

  defp check_limits(binary, %{type: type} = attribute) when type in [:string, :bytes] do
    check_size(byte_size(binary), attribute.filterable)
  end

  defp check_limits(strings, %{type: {:array, :string}} = attribute) do
    sizes = Enum.map(strings, &byte_size/1)

    with :ok <- check_size(Enum.sum(sizes), false) do
      check_size(Enum.max(sizes, fn -> 0 end), attribute.filterable)
    end
  end

  defp check_limits(weights, %{type: {:sparse_vector, _}}) when map_size(weights) > @max_sparse_dims do
    {:error, "turbopuffer sparse vectors can have at most #{@max_sparse_dims} dimensions"}
  end

  defp check_limits(_value, _attribute), do: :ok

  defp check_size(bytes, _filterable) when bytes > @max_value_bytes do
    {:error, "it's #{bytes} bytes, over turbopuffer's 8 MiB limit per value"}
  end

  defp check_size(bytes, true) when bytes > @max_filterable_value_bytes do
    {:error,
     "it's #{bytes} bytes, over turbopuffer's 4 KiB limit for filterable values " <>
       "(set `filterable: false` or enable full-text search)"}
  end

  defp check_size(_bytes, _filterable), do: :ok

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
  defp cast_value(values, {:array, element}) when is_list(values), do: cast_list(values, &cast_element(&1, element))
  defp cast_value(values, {:vector, _, _} = type) when is_list(values), do: cast_vector(values, type)

  defp cast_value(vectors, {:multi_vector, dims, element}) when is_list(vectors) do
    cast_list(vectors, &cast_vector(&1, {:vector, dims, element}))
  end

  defp cast_value(%{} = weights, {:sparse_vector, _}) when not is_struct(weights) do
    Enum.reduce_while(weights, {:ok, %{}}, fn
      {key, weight}, {:ok, acc} when (is_binary(key) or is_atom(key)) and is_number(weight) ->
        {:cont, {:ok, Map.put(acc, to_string(key), weight / 1)}}

      _, _ ->
        {:halt, :error}
    end)
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

  defp cast_vector(values, {:vector, dims, element}) when is_list(values) and length(values) == dims do
    max = if element == :f16, do: @f16_max, else: @f32_max

    cast_list(values, fn
      value when element == :i8 and is_integer(value) and value in -128..127 -> {:ok, value}
      value when element != :i8 and is_number(value) and abs(value) <= max -> {:ok, value / 1}
      _ -> :error
    end)
  end

  defp cast_vector(_values, _type), do: :error

  defp cast_list(values, cast_fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case cast_fun.(value) do
        {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp encode(nil, _type), do: nil
  defp encode(%DateTime{} = datetime, :datetime), do: DateTime.to_iso8601(datetime)
  defp encode(datetimes, {:array, :datetime}), do: Enum.map(datetimes, &DateTime.to_iso8601/1)
  defp encode(bytes, :bytes), do: Base.encode64(bytes)

  # turbopuffer's compact vector encoding is base64 little-endian f32, whatever the schema's element type.
  defp encode(vector, {:vector, _dims, _element}) do
    Base.encode64(for value <- vector, into: <<>>, do: <<value::float-32-little>>)
  end

  defp encode(value, _type), do: value

  defp load_value(base64, :bytes) when is_binary(base64), do: Base.decode64(base64)

  defp load_value(values, {:array, :datetime}) when is_list(values) do
    cast_list(values, fn
      nil -> :error
      value -> load_value(value, :datetime)
    end)
  end

  # Unlike writes, base64 vectors in query responses use the schema's element type.
  defp load_value(base64, {:vector, dims, element} = type) when is_binary(base64) do
    with {:ok, binary} <- Base.decode64(base64),
         true <- byte_size(binary) == dims * element_bytes(element) do
      cast_vector(decode_elements(binary, element), type)
    else
      _ -> :error
    end
  end

  defp load_value(values, {:vector, _dims, :i8} = type) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_float(value) and value == trunc(value) -> trunc(value)
      value -> value
    end)
    |> cast_vector(type)
  end

  defp load_value(vectors, {:multi_vector, dims, element}) when is_list(vectors) do
    cast_list(vectors, &load_value(&1, {:vector, dims, element}))
  end

  defp load_value(value, type), do: cast_value(value, type)

  defp element_bytes(:f32), do: 4
  defp element_bytes(:f16), do: 2
  defp element_bytes(:i8), do: 1

  defp decode_elements(binary, :f32), do: for(<<value::float-32-little <- binary>>, do: value)
  defp decode_elements(binary, :f16), do: for(<<value::float-16-little <- binary>>, do: value)
  defp decode_elements(binary, :i8), do: for(<<value::signed-8 <- binary>>, do: value)
end
