defmodule Ecto.Adapters.Turbopuffer do
  @moduledoc """
  An Ecto adapter for [turbopuffer](https://turbopuffer.com). Each schema is a namespace, every field uses the `TP`
  type, and searches are ordinary Ecto queries built with `TP.Query`.

      defmodule MyApp.Search do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Turbopuffer
      end

      config :my_app, MyApp.Search,
        api_key: System.fetch_env!("TURBOPUFFER_API_KEY"),
        region: "gcp-us-central1"

  Requests go through the `turbopuffer` driver, so the repo also takes `Turbopuffer.Client.new/1`'s options:
  `:base_url`, `:finch_name`, `:json_library`, `:max_retries` and `:retry_delay`. `:receive_timeout` sets how
  long to wait for a response, 60 seconds by default. For calls outside Ecto, `client/1` returns the repo's
  `Turbopuffer.Client`. A failed request raises `TP.Error`.

  ## Namespaces

  A schema's source is its namespace. An Ecto prefix, from `@schema_prefix`, the `:prefix` option, or the repo's
  `default_options/1`, is prepended with a dash: `prefix: "staging"` reads and writes `staging-card_stacks`.

  ## Writes

  Every write sends the schema's `TP.schema/1` and `TP.distance_metric/1`, so a namespace is created or extended by
  its first write.

    * `insert` and `insert_all` upsert whole documents. Like Ecto's other adapters, they refuse to overwrite an
      existing id by default: `insert` returns a `unique_constraint(:id)` error and `insert_all` raises. Pass
      `on_conflict: :nothing` to skip existing ids or `on_conflict: :replace_all` to overwrite them.
      turbopuffer can't replace only some fields of an existing document, so other `:on_conflict` values raise.
    * `insert_all` sends at most 30 rows per request for schemas with native embedding, turbopuffer's limit, and
      1,000 otherwise. Set `:batch_size` to change that. Batches aren't atomic.
    * `update` patches the changed fields. turbopuffer can't change ids, or patch vectors or the text it embeds
      natively, so changing one raises; upsert instead. `update` and `delete` raise `Ecto.StaleEntryError` when the
      id doesn't exist.
    * `update_all` (`set` only) and `delete_all` patch and delete by filter, up to turbopuffer's 50k and 5M
      document limits per call.

  ## Queries

  `Repo.all`, `one`, `get`, `exists?`, `aggregate` and `stream` work, with these limits:

    * turbopuffer returns at most 10,000 rows per query. Queries ordered by id, or not ordered, page through
      everything when there's no limit; any other ordering needs a limit.
    * `order_by` takes either up to 8 fields or one search from `TP.Query`, not both.
    * Aggregations support `count()` and `sum/1`, optionally with `group_by`.
    * `union_all` sends the queries together as a multi-query, each keeping its own ranking and limit, and returns
      their rows one after another. Pass `rerank_by: :rrf` (or `{:rrf, weights: [2, 1], rank_constant: 60,
      limit: 20, offset: 0}`) to have turbopuffer fuse them into one ranking with reciprocal rank fusion.
    * `consistency: :eventual` trades freshness for throughput. See `docs/turbopuffer/query.md#param-consistency`.
    * A namespace that hasn't been written to yet reads as empty.
    * No joins, subqueries, distinct, or having.

  Every request emits the repo's `[..., :query]` telemetry event.
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Queryable

  alias Ecto.Adapters.Turbopuffer.Query

  @client_options [:api_key, :region, :base_url, :finch_name, :json_library, :max_retries, :retry_delay]
  @embed_batch_size 30
  @batch_size 1_000
  @insert_only ["id", "Eq", nil]
  @existing ["id", "NotEq", nil]

  @doc "The `Turbopuffer.Client` behind a running repo, for calls outside Ecto."
  @spec client(Ecto.Repo.t() | pid() | atom()) :: Turbopuffer.Client.t()
  def client(repo), do: Ecto.Adapter.lookup_meta(repo).client

  @doc "The namespace `schema` reads and writes, under an optional Ecto prefix."
  @spec namespace(module(), String.t() | nil) :: String.t()
  def namespace(schema, prefix \\ nil) do
    Query.namespace(schema.__schema__(:source), prefix || schema.__schema__(:prefix))
  end

  # ------------------------------------------------------------------------------------------------
  # Ecto.Adapter
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.Adapter
  defmacro __before_compile__(_env), do: :ok

  @impl Ecto.Adapter
  def ensure_all_started(_config, type), do: Application.ensure_all_started(:turbopuffer, type)

  @impl Ecto.Adapter
  def init(config) do
    repo = Keyword.fetch!(config, :repo)

    meta = %{
      client: config |> Keyword.take(@client_options) |> Turbopuffer.Client.new(),
      request_opts: [receive_timeout: Keyword.get(config, :receive_timeout, 60_000)],
      telemetry: {repo, Keyword.fetch!(config, :telemetry_prefix) ++ [:query]}
    }

    # Requests go through the driver's connection pool, so the repo has no processes of its own.
    {:ok, %{id: {__MODULE__, repo}, start: {Agent, :start_link, [fn -> :ok end]}}, meta}
  end

  @impl Ecto.Adapter
  def checkout(_meta, _opts, fun), do: fun.()

  @impl Ecto.Adapter
  def checked_out?(_meta), do: false

  @impl Ecto.Adapter
  def loaders(_primitive, type), do: [type]

  @impl Ecto.Adapter
  def dumpers(_primitive, type), do: [type]

  # ------------------------------------------------------------------------------------------------
  # Ecto.Adapter.Schema
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.Adapter.Schema
  def autogenerate(:id),
    do: raise(ArgumentError, "turbopuffer has no auto-incrementing ids; use a string or uuid TP id")

  def autogenerate(:binary_id), do: Ecto.UUID.generate()
  def autogenerate(:embed_id), do: Ecto.UUID.generate()

  @impl Ecto.Adapter.Schema
  def insert(meta, schema_meta, fields, on_conflict, returning, opts) do
    no_returning!(returning)

    case upsert(meta, schema_meta, [TP.__row__(schema_meta.schema, fields)], on_conflict, opts) do
      1 -> {:ok, []}
      0 when elem(on_conflict, 0) == :raise -> {:invalid, [unique: "#{schema_meta.source}_id_index"]}
      0 -> {:ok, []}
    end
  end

  @impl Ecto.Adapter.Schema
  def insert_all(meta, schema_meta, _header, rows, on_conflict, returning, placeholders, opts) do
    no_returning!(returning)

    schema =
      schema_meta.schema || raise ArgumentError, "turbopuffer's insert_all needs a schema to know the namespace's types"

    rows =
      Enum.map(rows, fn fields ->
        TP.__row__(schema, Enum.map(fields, &resolve_placeholder(&1, placeholders)))
      end)

    count = upsert(meta, schema_meta, rows, on_conflict, opts)

    if elem(on_conflict, 0) == :raise and count < length(rows) do
      raise ArgumentError,
            "#{length(rows) - count} of #{length(rows)} ids already exist in #{meta_namespace(schema_meta)}, so they " <>
              "weren't inserted. Pass on_conflict: :replace_all to overwrite them or :nothing to skip them."
    end

    {count, nil}
  end

  @impl Ecto.Adapter.Schema
  def update(meta, %{schema: schema} = schema_meta, fields, filters, returning, opts) do
    no_returning!(returning)
    {id, condition} = id_and_condition(filters)
    attributes = Map.new(TP.attributes(schema), &{&1.name, &1})

    patch =
      Map.new(fields, fn {source, value} ->
        attribute = Map.fetch!(attributes, Atom.to_string(source))

        if message = TP.Attribute.patch_error(attribute) do
          raise ArgumentError, "#{message} (#{inspect(schema)}.#{attribute.field})"
        end

        {attribute.name, value}
      end)

    body =
      schema
      |> write_body()
      |> Map.put("patch_rows", [Map.put(patch, "id", id)])
      |> put("patch_condition", condition)

    if write!(meta, meta_namespace(schema_meta), body, opts) == 1, do: {:ok, []}, else: {:error, :stale}
  end

  @impl Ecto.Adapter.Schema
  def delete(meta, schema_meta, filters, returning, opts) do
    no_returning!(returning)
    {id, condition} = id_and_condition(filters)
    condition = if condition, do: ["And", [@existing, condition]], else: @existing
    body = %{"deletes" => [id], "delete_condition" => condition}

    if write!(meta, meta_namespace(schema_meta), body, opts) == 1, do: {:ok, []}, else: {:error, :stale}
  end

  # ------------------------------------------------------------------------------------------------
  # Ecto.Adapter.Queryable
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.Adapter.Queryable
  def prepare(operation, query), do: {:nocache, {operation, query}}

  @impl Ecto.Adapter.Queryable
  def execute(meta, _query_meta, {:nocache, {:all, query}}, params, opts) do
    rows = query |> Query.all(params, opts) |> pages(meta, opts) |> Enum.concat()
    {length(rows), rows}
  end

  def execute(meta, _query_meta, {:nocache, {operation, query}}, params, opts) do
    plan = apply(Query, operation, [query, params])
    {write!(meta, plan.namespace, plan.body, opts), nil}
  end

  @impl Ecto.Adapter.Queryable
  def stream(meta, _query_meta, {:nocache, {:all, query}}, params, opts) do
    query |> Query.all(params, opts) |> pages(meta, opts) |> Stream.map(&{length(&1), &1})
  end

  # ------------------------------------------------------------------------------------------------
  # PRIVATE
  # ------------------------------------------------------------------------------------------------

  defp pages(plan, meta, opts) do
    Stream.unfold(plan.body, fn
      nil ->
        nil

      body ->
        case request(meta, :query, plan.namespace, body, opts) do
          {:ok, response} -> Query.page(plan, response)
          {:error, %TP.Error{status: 404}} -> Query.empty_page(plan)
          {:error, error} -> raise error
        end
    end)
  end

  # The number of documents a write changed. Patches and deletes on a namespace that doesn't exist yet change none.
  defp write!(meta, namespace, body, opts) do
    case request(meta, :write, namespace, body, opts) do
      {:ok, %{"rows_affected" => count}} -> count
      {:error, %TP.Error{status: 404}} -> 0
      {:error, error} -> raise error
    end
  end

  defp upsert(meta, %{schema: schema} = schema_meta, rows, on_conflict, opts) do
    condition = upsert_condition!(schema, on_conflict)
    embeds? = Enum.any?(TP.attributes(schema), &Map.has_key?(&1.schema_entry, "embed"))
    batch_size = Keyword.get(opts, :batch_size, if(embeds?, do: @embed_batch_size, else: @batch_size))
    namespace = meta_namespace(schema_meta)

    rows
    |> Enum.chunk_every(batch_size)
    |> Enum.map(fn batch ->
      body = schema |> write_body() |> Map.put("upsert_rows", batch) |> put("upsert_condition", condition)
      write!(meta, namespace, body, opts)
    end)
    |> Enum.sum()
  end

  defp upsert_condition!(_schema, {mode, _, _}) when mode in [:raise, :nothing], do: @insert_only

  defp upsert_condition!(schema, {fields, _, _}) when is_list(fields) do
    all = Enum.map(schema.__schema__(:fields), &schema.__schema__(:field_source, &1))
    keys = Enum.map(schema.__schema__(:primary_key), &schema.__schema__(:field_source, &1))

    case (all -- keys) -- fields do
      [] ->
        nil

      missing ->
        raise ArgumentError,
              "turbopuffer upserts replace whole documents, so on_conflict must replace every field, " <>
                "e.g. :replace_all. It leaves out #{inspect(missing)}."
    end
  end

  defp upsert_condition!(_schema, _on_conflict) do
    raise ArgumentError, "turbopuffer can't run an update on conflict; use :replace_all, :nothing, or :raise"
  end

  defp write_body(schema) do
    put(%{"schema" => TP.schema(schema)}, "distance_metric", TP.distance_metric(schema))
  end

  defp id_and_condition(filters) do
    {ids, others} = Enum.split_with(filters, fn {source, _value} -> source == :id end)

    condition =
      case Enum.map(others, fn {source, value} -> [Atom.to_string(source), "Eq", value] end) do
        [] -> nil
        [condition] -> condition
        conditions -> ["And", conditions]
      end

    {Keyword.fetch!(ids, :id), condition}
  end

  defp resolve_placeholder({source, {:placeholder, index}}, placeholders),
    do: {source, Enum.at(placeholders, index - 1)}

  defp resolve_placeholder({source, %Ecto.Query{}}, _placeholders) do
    raise ArgumentError, "turbopuffer can't insert the result of a query into #{source}"
  end

  defp resolve_placeholder(field, _placeholders), do: field

  defp no_returning!([]), do: :ok

  defp no_returning!(fields) do
    raise ArgumentError, "turbopuffer writes can't return fields, got: #{inspect(fields)}"
  end

  defp meta_namespace(%{source: source, prefix: prefix}), do: Query.namespace(source, prefix)

  defp request(%{client: client, telemetry: {repo, event}} = meta, kind, namespace, body, opts) do
    path = if kind == :query, do: "/v2/namespaces/#{namespace}/query", else: "/v2/namespaces/#{namespace}"
    start = System.monotonic_time()
    result = client |> Turbopuffer.Client.post(path, body, meta.request_opts) |> result()

    :telemetry.execute(event, %{total_time: System.monotonic_time() - start}, %{
      type: :ecto_turbopuffer_query,
      repo: repo,
      kind: kind,
      source: namespace,
      query: body,
      result: result,
      options: Keyword.get(opts, :telemetry_options, [])
    })

    result
  end

  defp result({:ok, body}), do: {:ok, body}

  defp result({:error, {:http_error, status, body}}) do
    message = if is_map(body) and is_binary(body["error"]), do: body["error"], else: inspect(body)
    {:error, %TP.Error{status: status, message: message}}
  end

  defp result({:error, reason}) do
    message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
    {:error, %TP.Error{message: message}}
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
