defmodule TP.Attribute do
  @moduledoc """
  A `TP` field's turbopuffer attribute, built when the schema compiles. `TP.Namespace` collects a schema's.

  Options mirror https://turbopuffer.com/docs/write#schema:

    * `:filterable` - boolean. Defaults to true, except that full-text search and pattern indexes turn it off.
      bytes and vectors can't be filterable.
    * `:regex` - boolean, `string` only
    * `:glob`, `:fuzzy` - boolean, `string` and `[]string`
    * `:full_text_search` - boolean or keyword list of `:tokenizer`, `:language`, `:stemming`,
      `:remove_stopwords`, `:case_sensitive`, `:ascii_folding`, `:max_token_length`, `:k1`, `:b`, `:k3`;
      `string` and `[]string`. The `pre_tokenized_array` tokenizer needs `[]string` and rejects the language settings.
    * `:ann` - `true`, required on `[N]` vectors. `[late_interaction: true]` on `[][N]` multi-vectors, or `false` to
      store them without an index. `use TP, distance_metric:` sets the namespace's distance metric.
    * `:sparse_knn` - `[distance_metric: :dot_product]`, `{}f16` only
    * `:embed` - model name or keyword list of `:model`, `:attribute`, `:dims`, `:dtype`, `string` only.
      turbopuffer stores the vector in `:attribute`, `embed_<name>` by default.

  `capabilities` lists what queries can do with the attribute, and `missing/2` says why one isn't allowed.
  """

  # Ecto passes every field option to TP.init/1, not just TP's.
  @ecto_field_options [
    :default,
    :source,
    :autogenerate,
    :read_after_writes,
    :virtual,
    :primary_key,
    :load_in_query,
    :redact,
    :foreign_key,
    :on_replace,
    :defaults,
    :where,
    :references,
    :skip_default_validation,
    :writable,
    :field,
    :schema
  ]

  @options [:filterable, :regex, :glob, :fuzzy, :full_text_search, :ann, :sparse_knn, :embed]

  # The options each kind of type takes. Scalars other than strings and bytes, and their arrays, can only be filterable.
  @supported %{
    string: [:filterable, :regex, :glob, :fuzzy, :full_text_search, :embed],
    string_array: [:filterable, :glob, :fuzzy, :full_text_search],
    vector: [:ann],
    multi_vector: [:ann],
    sparse_vector: [:sparse_knn],
    bytes: [],
    other: [:filterable]
  }
  @kind_names [
    string: "string",
    string_array: "[]string",
    vector: "[N] vector",
    multi_vector: "[][N] multi-vector",
    sparse_vector: "{}f16"
  ]

  @tokenizers ~w(word_v4 word_v3 word_v2 word_v1 word_v0 pre_tokenized_array)
  @languages ~w(arabic danish dutch english finnish french german greek hungarian italian norwegian portuguese
                romanian russian spanish swedish tamil turkish)
  @embed_dtypes ~w(f32 f16 i8)
  @id_types [:string, :uint, :uuid]
  @max_name_bytes 128

  @enforce_keys [:field, :name, :type]
  defstruct [:field, :name, :type, :embed, primary_key: false, filterable: false, capabilities: [], options: %{}]

  @typedoc """
  What a query can do with an attribute: filter it (`:filter`), match it with a pattern or text index (`:glob`,
  `:regex`, `:fuzzy`, `:full_text_search`), rank it by vector (`:ann` with an index, `:vector` exactly), by
  `embed(text)` (`:embed`, or `:embed_model` when the query names the model), or by sparse vector
  (`:sparse_knn`), or patch it in place (`:patch`).
  """
  @type capability ::
          :filter
          | :glob
          | :regex
          | :fuzzy
          | :full_text_search
          | :ann
          | :vector
          | :embed
          | :embed_model
          | :sparse_knn
          | :patch

  @typedoc """
  Native embedding: turbopuffer embeds the attribute's text with `model` and stores the vector in `target`, which
  the schema named when `explicit_target?`.
  """
  @type embed :: %{
          model: String.t(),
          target: String.t(),
          explicit_target?: boolean(),
          dims: pos_integer() | nil,
          dtype: String.t() | nil
        }

  @typedoc "`options` holds the validated schema options, as turbopuffer's JSON values, for `to_schema/1`."
  @type t :: %__MODULE__{
          field: atom(),
          name: String.t(),
          type: TP.Types.t(),
          primary_key: boolean(),
          filterable: boolean(),
          capabilities: [capability()],
          embed: embed() | nil,
          options: %{atom() => term()}
        }

  @doc """
  Builds the attribute from a `TP` field's options, which include Ecto's `:field`. Raises `ArgumentError` when an
  option is unknown, malformed, or not supported by the type.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    type = type!(opts)
    primary_key = opts[:primary_key] == true
    name = name!(opts, primary_key)
    key!(opts, type, primary_key)
    options = options!(opts, type, primary_key)
    filterable = not primary_key and filterable?(type, options)
    embed = embed(options[:embed], name)

    %__MODULE__{
      field: opts[:field],
      name: name,
      type: type,
      primary_key: primary_key,
      filterable: filterable,
      embed: embed,
      options: options,
      capabilities: capabilities(type, primary_key, filterable, options, embed)
    }
  rescue
    error in ArgumentError -> reraise ArgumentError, error.message <> location(opts), __STACKTRACE__
  end

  @doc """
  Why a query can't use the attribute for `capability`, or `nil` when it can.
  """
  @spec missing(t(), capability()) :: String.t() | nil
  def missing(%__MODULE__{} = attribute, capability) do
    unless capability in attribute.capabilities, do: requirement(attribute, capability)
  end

  @doc """
  The attribute's entry in turbopuffer's namespace schema, e.g. `%{"type" => "string", "full_text_search" => true}`.
  """
  @spec to_schema(t()) :: %{String.t() => term()}
  def to_schema(%__MODULE__{} = attribute) do
    Map.new(attribute.options, fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("type", TP.Types.encode(attribute.type))
  end

  defp type!(opts) do
    case Keyword.fetch(opts, :type) do
      {:ok, type} -> TP.Types.decode(type)
      :error -> raise ArgumentError, "TP fields need a turbopuffer `type:`, e.g. `type: \"string\"`"
    end
  end

  defp name!(opts, primary_key) do
    field = opts[:field] || raise ArgumentError, "TP needs the field's name; Ecto schemas pass it as `:field`"
    name = to_string(opts[:source] || field)

    cond do
      String.starts_with?(name, "$") ->
        raise ArgumentError, "turbopuffer reserves attribute names starting with $"

      byte_size(name) > @max_name_bytes ->
        raise ArgumentError, "turbopuffer attribute names can be at most #{@max_name_bytes} bytes"

      name == "id" and not primary_key ->
        raise ArgumentError, "turbopuffer reserves `id` for the primary key"

      primary_key and name != "id" ->
        raise ArgumentError, "turbopuffer ids must be named `id` (add `source: :id` to keep the field name)"

      true ->
        name
    end
  end

  defp key!(opts, type, primary_key) do
    cond do
      primary_key and type not in @id_types ->
        raise ArgumentError, "turbopuffer ids must be string, uint, or uuid; got #{TP.Types.encode(type)}"

      opts[:autogenerate] == true and type != :uuid ->
        raise ArgumentError, "TP can only autogenerate uuid values, not #{TP.Types.encode(type)}"

      true ->
        :ok
    end
  end

  defp options!(opts, type, primary_key) do
    options = Keyword.drop(opts, [:type | @ecto_field_options])

    case Keyword.keys(options) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown turbopuffer option(s) #{inspect(unknown)}"
    end

    supported = if primary_key, do: [], else: Map.fetch!(@supported, kind(type))

    for {key, _value} <- options, key not in supported do
      raise ArgumentError, unsupported(key, type, primary_key)
    end

    if kind(type) == :vector and not Keyword.has_key?(options, :ann) do
      raise ArgumentError, "#{TP.Types.encode(type)} attributes require `ann: true`"
    end

    Map.new(options, fn {key, value} -> {key, option!(key, value, type)} end)
  end

  defp kind(:string), do: :string
  defp kind({:array, :string}), do: :string_array
  defp kind({:vector, _dims, _element}), do: :vector
  defp kind({:multi_vector, _dims, _element}), do: :multi_vector
  defp kind({:sparse_vector, _element}), do: :sparse_vector
  defp kind(:bytes), do: :bytes
  defp kind(_type), do: :other

  defp unsupported(key, _type, true), do: "turbopuffer ids can't take #{inspect(key)}"
  defp unsupported(:filterable, type, false), do: "#{TP.Types.encode(type)} attributes can't be filterable"

  defp unsupported(key, type, false) do
    kinds = for {kind, name} <- @kind_names, key in @supported[kind], do: name
    "#{inspect(key)} requires a #{Enum.join(kinds, " or ")} attribute, not #{TP.Types.encode(type)}"
  end

  defp option!(key, value, _type) when key in [:filterable, :regex, :glob, :fuzzy], do: boolean!(key, value)
  defp option!(:full_text_search, value, _type) when is_boolean(value), do: value

  defp option!(:full_text_search, config, type) do
    :full_text_search
    |> config!(config, fn
      :tokenizer, v -> enum!(:tokenizer, v, @tokenizers)
      :language, v -> enum!(:language, v, @languages)
      :max_token_length, v when is_integer(v) and v in 1..254 -> v
      :max_token_length, v -> invalid!(:max_token_length, v, "an integer between 1 and 254")
      :b, v when is_number(v) and v >= 0 and v <= 1 -> v
      :b, v -> invalid!(:b, v, "a number between 0.0 and 1.0")
      key, v when key in [:k1, :k3] and is_number(v) and v > 0 -> v
      key, v when key in [:k1, :k3] -> invalid!(key, v, "a number greater than 0")
      key, v when key in [:stemming, :remove_stopwords, :case_sensitive, :ascii_folding] -> boolean!(key, v)
      key, _ -> unknown_option!(:full_text_search, key)
    end)
    |> pre_tokenized!(type)
  end

  defp option!(:ann, true, {:vector, _, _}), do: true

  defp option!(:ann, value, {:vector, _, _} = type) do
    hint =
      if is_list(value) and Keyword.has_key?(value, :distance_metric),
        do: "; set the namespace's distance metric with `use TP, distance_metric: ...`",
        else: ""

    raise ArgumentError, "#{TP.Types.encode(type)} attributes take `ann: true`, got: #{inspect(value)}#{hint}"
  end

  defp option!(:ann, false, {:multi_vector, _, _}), do: false

  defp option!(:ann, value, {:multi_vector, _, _} = type) do
    config = if is_list(value), do: config!(:ann, value, fn key, v -> ann_setting!(key, v) end)

    if config != %{"late_interaction" => true} do
      raise ArgumentError,
            "#{TP.Types.encode(type)} attributes take `ann: [late_interaction: true]`, or `ann: false` to skip the " <>
              "index, got: #{inspect(value)}"
    end

    config
  end

  defp option!(:sparse_knn, value, _type) do
    config =
      config!(:sparse_knn, value, fn
        :distance_metric, v -> enum!(:distance_metric, v, ~w(dot_product))
        key, _ -> unknown_option!(:sparse_knn, key)
      end)

    unless Map.has_key?(config, "distance_metric"), do: raise(ArgumentError, "sparse_knn requires :distance_metric")
    config
  end

  defp option!(:embed, model, _type) when is_binary(model), do: nonempty_string!(:embed, model)

  defp option!(:embed, value, _type) do
    config =
      config!(:embed, value, fn
        key, v when key in [:model, :attribute] -> nonempty_string!(key, v)
        :dims, v when is_integer(v) and v > 0 -> v
        :dims, v -> invalid!(:dims, v, "a positive integer")
        :dtype, v -> enum!(:dtype, v, @embed_dtypes)
        key, _ -> unknown_option!(:embed, key)
      end)

    unless Map.has_key?(config, "model"), do: raise(ArgumentError, "embed requires :model")
    config
  end

  defp ann_setting!(:late_interaction, value), do: boolean!(:late_interaction, value)
  defp ann_setting!(key, _value), do: unknown_option!(:ann, key)

  defp pre_tokenized!(%{"tokenizer" => "pre_tokenized_array"} = config, type) do
    if type != {:array, :string} do
      raise ArgumentError, "the pre_tokenized_array tokenizer requires a []string attribute"
    end

    conflicts =
      Enum.filter(
        [
          Map.has_key?(config, "language") && "language",
          config["stemming"] == true && "stemming: true",
          config["remove_stopwords"] == true && "remove_stopwords: true",
          config["case_sensitive"] == false && "case_sensitive: false"
        ],
        & &1
      )

    if conflicts != [] do
      raise ArgumentError, "the pre_tokenized_array tokenizer can't be combined with #{Enum.join(conflicts, ", ")}"
    end

    config
  end

  defp pre_tokenized!(config, _type), do: config

  defp filterable?(type, options) do
    TP.Types.filterable?(type) and
      Map.get_lazy(options, :filterable, fn ->
        not Enum.any?([:full_text_search, :regex, :glob, :fuzzy], &(options[&1] not in [nil, false]))
      end)
  end

  defp embed(nil, _name), do: nil
  defp embed(model, name) when is_binary(model), do: embed(%{"model" => model}, name)

  defp embed(config, name) do
    %{
      model: config["model"],
      target: config["attribute"] || "embed_" <> name,
      explicit_target?: Map.has_key?(config, "attribute"),
      dims: config["dims"],
      dtype: config["dtype"]
    }
  end

  defp capabilities(type, primary_key, filterable, options, embed) do
    [
      filter: primary_key or filterable,
      # Glob matches strings, and turbopuffer still runs it on those that are only filterable.
      glob: kind(type) in [:string, :string_array] and (primary_key or filterable or options[:glob] == true),
      regex: options[:regex] == true,
      fuzzy: options[:fuzzy] == true,
      full_text_search: options[:full_text_search] not in [nil, false],
      ann: options[:ann] not in [nil, false],
      vector: TP.Types.vector?(type),
      embed: embed != nil,
      # A vector attribute can be ranked by embedded text when the query names the model.
      embed_model: embed != nil or kind(type) == :vector,
      sparse_knn: kind(type) == :sparse_vector,
      patch: not (primary_key or TP.Types.vector?(type) or embed != nil)
    ]
    |> Enum.filter(fn {_capability, able} -> able end)
    |> Keyword.keys()
  end

  defp requirement(%{primary_key: true} = attribute, :patch),
    do: "#{inspect(attribute.field)} can't be patched: turbopuffer ids can't change"

  defp requirement(attribute, :patch) do
    "#{inspect(attribute.field)} can't be patched: turbopuffer can't patch vectors or the text it embeds, so upsert " <>
      "the whole document with `on_conflict: :replace_all`"
  end

  defp requirement(attribute, :filter), do: "#{inspect(attribute.field)} isn't filterable"

  defp requirement(attribute, :glob) do
    if kind(attribute.type) in [:string, :string_array],
      do: "#{inspect(attribute.field)} needs `glob: true` or to be filterable",
      else: "#{inspect(attribute.field)} isn't a string or []string, so it can't be matched with a glob"
  end

  defp requirement(attribute, :ann), do: "#{inspect(attribute.field)} has no ANN index"
  defp requirement(attribute, :vector), do: "#{inspect(attribute.field)} isn't a vector"

  defp requirement(attribute, :embed) do
    if kind(attribute.type) == :vector,
      do: "#{inspect(attribute.field)} is a vector, so embed(text) needs the model: embed(^text, ^model)",
      else: "#{inspect(attribute.field)} isn't embedded text"
  end

  defp requirement(attribute, :embed_model), do: "#{inspect(attribute.field)} isn't embedded text or a vector"
  defp requirement(attribute, :sparse_knn), do: "#{inspect(attribute.field)} isn't a sparse vector"
  defp requirement(attribute, index), do: "#{inspect(attribute.field)} needs `#{index}:`"

  defp config!(option, config, validate) do
    unless is_list(config) and Keyword.keyword?(config), do: invalid!(option, config, "a keyword list")
    Map.new(config, fn {key, value} -> {Atom.to_string(key), validate.(key, value)} end)
  end

  defp unknown_option!(option, key), do: raise(ArgumentError, "unknown #{inspect(option)} option #{inspect(key)}")

  defp enum!(key, value, allowed) do
    string = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value
    if string in allowed, do: string, else: invalid!(key, value, "one of #{Enum.join(allowed, ", ")}")
  end

  defp boolean!(_key, value) when is_boolean(value), do: value
  defp boolean!(key, value), do: invalid!(key, value, "a boolean")

  defp nonempty_string!(_key, value) when is_binary(value) and value != "", do: value
  defp nonempty_string!(key, value), do: invalid!(key, value, "a non-empty string")

  defp invalid!(key, value, expected) do
    raise ArgumentError, "#{inspect(key)} must be #{expected}, got: #{inspect(value)}"
  end

  defp location(opts) do
    case {opts[:field], opts[:schema]} do
      {nil, _} -> ""
      {field, nil} -> " (field #{inspect(field)})"
      {field, schema} -> " (field #{inspect(field)} in #{inspect(schema)})"
    end
  end
end
