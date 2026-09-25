defmodule TP.Namespace do
  @moduledoc """
  An Ecto schema's turbopuffer namespace: its attributes, the schema and distance metric every write declares, and
  the rules turbopuffer applies to each document written to it.

  `use TP` checks turbopuffer's namespace-wide rules when the schema compiles: a valid namespace name, one `id`
  primary key, 1,024 attributes, 8 vector columns (embedded attributes' computed vectors count), 4 embedded
  attributes, and a distance metric when there are vector columns.

  `row!/2` and `patch!/2` enforce turbopuffer's limits on values being written: 64-byte ids, 4 KiB filterable
  values, 8 MiB values, and 1,024 sparse dimensions. Queries don't, so a filter can compare against any value.
  """

  @max_attributes 1_024
  @max_vector_columns 8
  @max_embedded_attributes 4
  @max_id_bytes 64
  @max_filterable_value_bytes 4_096
  @max_value_bytes 8 * 1024 * 1024
  @max_sparse_dims 1_024

  @enforce_keys [:module, :attributes, :by_name, :schema, :distance_metric]
  defstruct [:module, :attributes, :by_name, :schema, :distance_metric, :num_shards, embeds?: false]

  @typedoc """
  `schema`, `distance_metric` and `num_shards` are what writes that store values declare. `by_name` keys the
  attributes by turbopuffer name, which is the field's source.
  """
  @type t :: %__MODULE__{
          module: module(),
          attributes: [TP.Attribute.t()],
          by_name: %{String.t() => TP.Attribute.t()},
          schema: %{String.t() => map() | String.t()},
          distance_metric: String.t() | nil,
          num_shards: pos_integer() | nil,
          embeds?: boolean()
        }

  @doc """
  The namespace of a schema that uses `TP`.
  """
  @spec new(module()) :: t()
  def new(module) do
    attributes = attributes(module)

    %__MODULE__{
      module: module,
      attributes: attributes,
      by_name: Map.new(attributes, &{&1.name, &1}),
      schema: Map.new(Enum.flat_map(attributes, &schema_entry/1)),
      distance_metric: module.__tp__(:distance_metric),
      num_shards: module.__tp__(:num_shards),
      embeds?: Enum.any?(attributes, & &1.embed)
    }
  end

  @doc false
  # Called by `use TP` once the schema compiles.
  def validate!(module) do
    namespace = new(module)
    attributes = namespace.attributes
    embedded = Enum.filter(attributes, & &1.embed)
    vector_columns = vector_columns(attributes)

    name!(module.__schema__(:source), nil)

    cond do
      Enum.count(attributes, & &1.primary_key) != 1 ->
        raise ArgumentError,
              "#{inspect(module)} needs one TP primary key, " <>
                "e.g. `@primary_key {:id, TP, type: \"string\", autogenerate: false}`"

      length(attributes) > @max_attributes ->
        raise ArgumentError,
              "#{inspect(module)} has #{length(attributes)} attributes; turbopuffer allows #{@max_attributes}"

      length(vector_columns) > @max_vector_columns ->
        raise ArgumentError,
              "#{inspect(module)} has #{length(vector_columns)} vector columns, counting embedded attributes' " <>
                "computed vectors; turbopuffer allows #{@max_vector_columns}"

      length(embedded) > @max_embedded_attributes ->
        raise ArgumentError,
              "#{inspect(module)} embeds #{length(embedded)} attributes; turbopuffer allows #{@max_embedded_attributes}"

      vector_columns != [] and namespace.distance_metric == nil ->
        raise ArgumentError,
              "#{inspect(module)} has vector columns, so turbopuffer needs a distance metric: " <>
                "add `use TP, distance_metric: :cosine_distance` (or :euclidean_squared)"

      true ->
        Enum.each(embedded, &validate_embed_target!(&1, namespace))
    end

    namespace
  end

  @doc """
  The turbopuffer namespace for an Ecto source and prefix: the prefix is prepended with a dash.
  """
  @spec name!(String.t(), String.t() | nil) :: String.t()
  def name!(source, prefix) do
    name = if prefix, do: "#{prefix}-#{source}", else: source

    if is_binary(name) and name =~ ~r/\A[A-Za-z0-9\-_.]{1,128}\z/ do
      name
    else
      raise ArgumentError, "turbopuffer namespace names must match [A-Za-z0-9-_.]{1,128}, got: #{inspect(name)}"
    end
  end

  @doc """
  The `schema`, `distance_metric` and `sharding` of a write that stores values, so the write creates or extends the
  namespace.
  """
  @spec write_params(t()) :: map()
  def write_params(%__MODULE__{} = ns) do
    %{"schema" => ns.schema}
    |> put("distance_metric", ns.distance_metric)
    |> put("sharding", ns.num_shards && %{"num_shards" => ns.num_shards})
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  @doc """
  A document to upsert, from the values Ecto dumped, keyed by field source. Raises when the id or a vector is
  missing, or a value breaks turbopuffer's limits.
  """
  @spec row!(t(), keyword()) :: %{String.t() => term()}
  def row!(%__MODULE__{} = ns, fields) do
    row = Map.new(fields, fn {source, value} -> {Atom.to_string(source), value} end)

    Enum.reduce(ns.attributes, row, fn attribute, row ->
      value = row[attribute.name]
      check_limits!(ns, attribute, value)

      cond do
        value != nil -> row
        attribute.primary_key -> raise ArgumentError, "cannot write #{inspect(ns.module)} without an id"
        match?({:vector, _, _}, attribute.type) -> Map.delete(row, require_embedded!(ns, attribute, row))
        true -> row
      end
    end)
  end

  @doc """
  The fields of a patch, from the values Ecto dumped, keyed by field source. Raises when turbopuffer can't patch a
  field or a value breaks its limits.
  """
  @spec patch!(t(), keyword()) :: %{String.t() => term()}
  def patch!(%__MODULE__{} = ns, fields) do
    Map.new(fields, fn {source, value} ->
      attribute = Map.fetch!(ns.by_name, Atom.to_string(source))

      if message = TP.Attribute.missing(attribute, :patch) do
        raise ArgumentError, "#{message} (#{inspect(ns.module)})"
      end

      check_limits!(ns, attribute, value)
      {attribute.name, value}
    end)
  end

  defp attributes(module) do
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

  # turbopuffer infers string ids, so only uuid and uint ids need declaring.
  defp schema_entry(%{primary_key: true, type: :string}), do: []
  defp schema_entry(%{primary_key: true} = attribute), do: [{attribute.name, TP.Types.encode(attribute.type)}]
  defp schema_entry(attribute), do: [{attribute.name, TP.Attribute.to_schema(attribute)}]

  defp vector_columns(attributes) do
    vectors = for %{type: type, name: name} <- attributes, TP.Types.vector?(type), do: name
    targets = for %{embed: %{target: target}} <- attributes, do: target
    Enum.uniq(vectors ++ targets)
  end

  # An embed that names its vector attribute has to name a declared vector it fits, so that queries can read it.
  defp validate_embed_target!(%{embed: %{explicit_target?: false}}, _ns), do: :ok

  defp validate_embed_target!(%{embed: embed} = attribute, ns) do
    where = "#{inspect(ns.module)}.#{attribute.field}"

    case ns.by_name[embed.target] do
      %{type: {:vector, dims, element}} ->
        if embed.dims not in [nil, dims] do
          raise ArgumentError, "#{where}: embed dims #{embed.dims} don't match #{embed.target}'s #{dims} dimensions"
        end

        if embed.dtype not in [nil, Atom.to_string(element)] do
          raise ArgumentError,
                "#{where}: embed dtype #{embed.dtype} doesn't match #{embed.target}'s #{element} elements"
        end

      _ ->
        raise ArgumentError,
              "#{where}: embed attribute #{inspect(embed.target)} must be an [N] vector field in the schema"
    end
  end

  # A vector that native embedding fills from a string attribute can be left out when that string is present.
  defp require_embedded!(ns, attribute, row) do
    name = attribute.name

    unless Enum.any?(ns.attributes, &(match?(%{embed: %{target: ^name}}, &1) and row[&1.name] != nil)) do
      raise ArgumentError,
            "cannot write #{inspect(ns.module)} without #{inspect(attribute.field)}: " <>
              "turbopuffer upserts must include every vector attribute"
    end

    attribute.name
  end

  defp check_limits!(ns, attribute, value) do
    with {:error, reason} <- limits(value, attribute) do
      raise ArgumentError, "cannot write #{inspect(ns.module)}.#{attribute.field}: #{reason}"
    end
  end

  defp limits(id, %{primary_key: true}) when is_binary(id) and byte_size(id) > @max_id_bytes do
    {:error, "turbopuffer ids can be at most #{@max_id_bytes} bytes, and it's #{byte_size(id)}"}
  end

  defp limits(string, %{type: :string} = attribute) when is_binary(string) do
    size(byte_size(string), attribute.filterable)
  end

  # Ecto dumped bytes to base64, and the limits apply to the decoded value.
  defp limits(base64, %{type: :bytes}) when is_binary(base64) do
    padding = byte_size(base64) - byte_size(String.trim_trailing(base64, "="))
    size(div(byte_size(base64) * 3, 4) - padding, false)
  end

  defp limits(strings, %{type: {:array, :string}} = attribute) when is_list(strings) do
    sizes = Enum.map(strings, &byte_size/1)

    with :ok <- size(Enum.sum(sizes), false) do
      size(Enum.max(sizes, fn -> 0 end), attribute.filterable)
    end
  end

  defp limits(weights, %{type: {:sparse_vector, _}}) when map_size(weights) > @max_sparse_dims do
    {:error, "turbopuffer sparse vectors can have at most #{@max_sparse_dims} dimensions"}
  end

  defp limits(_value, _attribute), do: :ok

  defp size(bytes, _filterable) when bytes > @max_value_bytes do
    {:error, "it's #{bytes} bytes, over turbopuffer's 8 MiB limit per value"}
  end

  defp size(bytes, true) when bytes > @max_filterable_value_bytes do
    {:error,
     "it's #{bytes} bytes, over turbopuffer's 4 KiB limit for filterable values " <>
       "(set `filterable: false` or enable full-text search)"}
  end

  defp size(_bytes, _filterable), do: :ok
end
