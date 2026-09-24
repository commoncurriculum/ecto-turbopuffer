defmodule TP.Attribute do
  @moduledoc """
  Validates a `TP` field's turbopuffer options and renders its entry in a namespace schema.

  Options mirror https://turbopuffer.com/docs/write#schema:

    * `:filterable` - boolean
    * `:regex` - boolean, `string` only
    * `:glob`, `:fuzzy` - boolean, `string`/`[]string` only
    * `:full_text_search` - boolean or keyword list of `:tokenizer`, `:language`, `:stemming`,
      `:remove_stopwords`, `:case_sensitive`, `:ascii_folding`, `:max_token_length`, `:k1`, `:b`, `:k3`.
      The `pre_tokenized_array` tokenizer needs `[]string` and rejects the language settings.
    * `:ann` - boolean or keyword list of `:distance_metric`, `:late_interaction`; required on `[N]` vectors
    * `:sparse_knn` - keyword list with `:distance_metric`, `{}f16` only
    * `:embed` - model name or keyword list of `:model`, `:attribute`, `:dims`, `:dtype`, `string` only
  """

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

  @tp_options [:type, :filterable, :regex, :glob, :fuzzy, :full_text_search, :ann, :sparse_knn, :embed]

  @tokenizers ~w(word_v4 word_v3 word_v2 word_v1 word_v0 pre_tokenized_array)
  @languages ~w(arabic danish dutch english finnish french german greek hungarian italian norwegian portuguese
                romanian russian spanish swedish tamil turkish)
  @distance_metrics ~w(cosine_distance euclidean_squared)
  @sparse_distance_metrics ~w(dot_product)
  @embed_dtypes ~w(f32 f16 i8)
  @id_types [:string, :uint, :uuid]
  @max_name_bytes 128

  @doc """
  Returns the attribute's schema entry, e.g. `%{"type" => "string", "full_text_search" => true}`.
  Raises `ArgumentError` when an option is unknown, malformed, or not supported by the type.
  """
  @spec schema_entry(TP.Types.t(), keyword()) :: %{String.t() => term()}
  def schema_entry(type, opts) do
    where = location(opts)

    case Enum.reject(Keyword.keys(opts), &(&1 in @tp_options or &1 in @ecto_field_options)) do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown turbopuffer option(s) #{inspect(unknown)} #{where}"
    end

    validate_name!(opts, where)
    if opts[:primary_key], do: validate_id!(type, opts, where)
    validate_ann_present!(type, opts, where)

    opts
    |> Keyword.take(@tp_options -- [:type])
    |> Enum.reduce(%{"type" => TP.Types.encode(type)}, fn {key, value}, entry ->
      Map.put(entry, Atom.to_string(key), option!(key, value, type, where))
    end)
  end

  @doc false
  def distance_metrics, do: @distance_metrics

  @doc """
  Whether turbopuffer indexes the attribute for filtering and sorting. It defaults to true, except that
  full-text search and pattern filters turn it off, and bytes and vectors can never be filtered.
  """
  @spec filterable?(TP.Types.t(), map()) :: boolean()
  def filterable?(type, entry) do
    cond do
      type == :bytes or (is_tuple(type) and elem(type, 0) != :array) -> false
      Map.has_key?(entry, "filterable") -> entry["filterable"]
      true -> not Enum.any?(~w(full_text_search regex glob fuzzy), &(entry[&1] not in [nil, false]))
    end
  end

  defp validate_name!(opts, where) do
    name = to_string(opts[:source] || opts[:field])

    cond do
      String.starts_with?(name, "$") ->
        raise ArgumentError, "turbopuffer reserves attribute names starting with $ #{where}"

      byte_size(name) > @max_name_bytes ->
        raise ArgumentError, "turbopuffer attribute names can be at most #{@max_name_bytes} bytes #{where}"

      name == "id" and !opts[:primary_key] ->
        raise ArgumentError, "turbopuffer reserves `id` for the primary key #{where}"

      true ->
        :ok
    end
  end

  defp validate_id!(type, opts, where) do
    unless type in @id_types do
      raise ArgumentError,
            "turbopuffer ids must be string, uint, or uuid; got #{TP.Types.encode(type)} #{where}"
    end

    if to_string(opts[:source] || opts[:field]) != "id" do
      raise ArgumentError, "turbopuffer ids must be named `id` (add `source: :id` to keep the field name) #{where}"
    end

    case Keyword.take(opts, @tp_options -- [:type]) do
      [] -> :ok
      options -> raise ArgumentError, "the turbopuffer id can't take #{inspect(Keyword.keys(options))} #{where}"
    end
  end

  defp validate_ann_present!({:vector, _, _} = type, opts, where) do
    unless opts[:ann] do
      raise ArgumentError, "#{TP.Types.encode(type)} attributes require `ann: true` (or ann options) #{where}"
    end
  end

  defp validate_ann_present!(_type, _opts, _where), do: :ok

  defp option!(:filterable, true, type, where) when type == :bytes or (is_tuple(type) and elem(type, 0) != :array) do
    raise ArgumentError, "#{TP.Types.encode(type)} attributes can't be filterable #{where}"
  end

  defp option!(key, value, type, where) when key in [:filterable, :regex, :glob, :fuzzy] do
    boolean!(key, value, where)

    cond do
      not value or key == :filterable -> :ok
      key == :regex and type != :string -> raise ArgumentError, ":regex requires a string attribute #{where}"
      true -> text_type!(key, type, where)
    end

    value
  end

  defp option!(:full_text_search, value, type, where) do
    text_type!(:full_text_search, type, where)

    if is_boolean(value) do
      value
    else
      value
      |> full_text_search_config!(where)
      |> validate_pre_tokenized!(type, where)
    end
  end

  defp option!(:ann, value, {:vector, _, _} = type, where) do
    case value do
      true -> true
      false -> raise ArgumentError, "#{TP.Types.encode(type)} attributes require `ann: true` #{where}"
      config -> ann_config!(config, false, where)
    end
  end

  defp option!(:ann, value, {:multi_vector, _, _} = type, where) do
    case value do
      false ->
        false

      true ->
        raise ArgumentError,
              "#{TP.Types.encode(type)} attributes need `ann: [late_interaction: true]` to build an index #{where}"

      config ->
        ann_config!(config, true, where)
    end
  end

  defp option!(:sparse_knn, value, {:sparse_vector, _}, where) do
    entry =
      config!(:sparse_knn, value, where, fn
        :distance_metric, v -> enum!(:distance_metric, v, @sparse_distance_metrics, where)
        key, _ -> unknown_option!(:sparse_knn, key, where)
      end)

    unless Map.has_key?(entry, "distance_metric") do
      raise ArgumentError, "sparse_knn requires :distance_metric #{where}"
    end

    entry
  end

  defp option!(:embed, model, :string, where) when is_binary(model), do: nonempty_string!(:embed, model, where)

  defp option!(:embed, value, :string, where) do
    entry =
      config!(:embed, value, where, fn
        key, v when key in [:model, :attribute] -> nonempty_string!(key, v, where)
        :dims, v when is_integer(v) and v > 0 -> v
        :dims, v -> invalid!(:dims, v, "a positive integer", where)
        :dtype, v -> enum!(:dtype, v, @embed_dtypes, where)
        key, _ -> unknown_option!(:embed, key, where)
      end)

    unless Map.has_key?(entry, "model"), do: raise(ArgumentError, "embed requires :model #{where}")
    entry
  end

  defp option!(key, _value, type, where) when key in [:ann, :sparse_knn, :embed] do
    raise ArgumentError, "#{inspect(key)} isn't supported on #{TP.Types.encode(type)} attributes #{where}"
  end

  defp full_text_search_config!(config, where) do
    config!(:full_text_search, config, where, fn
      :tokenizer, v -> enum!(:tokenizer, v, @tokenizers, where)
      :language, v -> enum!(:language, v, @languages, where)
      :max_token_length, v when is_integer(v) and v in 1..254 -> v
      :max_token_length, v -> invalid!(:max_token_length, v, "an integer between 1 and 254", where)
      :b, v when is_number(v) and v >= 0 and v <= 1 -> v
      :b, v -> invalid!(:b, v, "a number between 0.0 and 1.0", where)
      key, v when key in [:k1, :k3] and is_number(v) and v > 0 -> v
      key, v when key in [:k1, :k3] -> invalid!(key, v, "a number greater than 0", where)
      key, v when key in [:stemming, :remove_stopwords, :case_sensitive, :ascii_folding] -> boolean!(key, v, where)
      key, _ -> unknown_option!(:full_text_search, key, where)
    end)
  end

  defp validate_pre_tokenized!(%{"tokenizer" => "pre_tokenized_array"} = config, type, where) do
    if type != {:array, :string} do
      raise ArgumentError, "the pre_tokenized_array tokenizer requires a []string attribute #{where}"
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
      raise ArgumentError,
            "the pre_tokenized_array tokenizer can't be combined with #{Enum.join(conflicts, ", ")} #{where}"
    end

    config
  end

  defp validate_pre_tokenized!(config, _type, _where), do: config

  defp ann_config!(config, multi_vector?, where) do
    entry =
      config!(:ann, config, where, fn
        :distance_metric, v -> enum!(:distance_metric, v, @distance_metrics, where)
        :late_interaction, v when multi_vector? -> boolean!(:late_interaction, v, where)
        key, _ -> unknown_option!(:ann, key, where)
      end)

    if multi_vector? and entry["late_interaction"] != true do
      raise ArgumentError, "an ANN index on a multi-vector attribute requires `late_interaction: true` #{where}"
    end

    entry
  end

  defp config!(option, config, where, validate) when is_list(config) do
    unless Keyword.keyword?(config), do: invalid!(option, config, "a boolean or keyword list", where)

    Map.new(config, fn {key, value} -> {Atom.to_string(key), validate.(key, value)} end)
  end

  defp config!(option, config, where, _validate), do: invalid!(option, config, "a keyword list", where)

  defp unknown_option!(option, key, where) do
    raise ArgumentError, "unknown #{inspect(option)} option #{inspect(key)} #{where}"
  end

  defp text_type!(_option, type, _where) when type in [:string, {:array, :string}], do: :ok

  defp text_type!(option, type, where) do
    raise ArgumentError,
          "#{inspect(option)} requires a string or []string attribute, not #{TP.Types.encode(type)} #{where}"
  end

  defp enum!(key, value, allowed, where) do
    string = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value
    if string in allowed, do: string, else: invalid!(key, value, "one of #{Enum.join(allowed, ", ")}", where)
  end

  defp boolean!(_key, value, _where) when is_boolean(value), do: value
  defp boolean!(key, value, where), do: invalid!(key, value, "a boolean", where)

  defp nonempty_string!(_key, value, _where) when is_binary(value) and value != "", do: value
  defp nonempty_string!(key, value, where), do: invalid!(key, value, "a non-empty string", where)

  defp invalid!(key, value, expected, where) do
    raise ArgumentError, "#{inspect(key)} must be #{expected}, got: #{inspect(value)} #{where}"
  end

  defp location(opts) do
    case {opts[:field], opts[:schema]} do
      {nil, _} -> ""
      {field, nil} -> "(field #{inspect(field)})"
      {field, schema} -> "(field #{inspect(field)} in #{inspect(schema)})"
    end
  end
end
