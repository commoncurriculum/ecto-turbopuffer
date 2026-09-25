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

  Requests go through the `turbopuffer` driver, so the repo also takes `Turbopuffer.Client.new/1`'s `:base_url`,
  `:max_retries` and `:retry_delay`. `:receive_timeout` sets how long to wait for a response, 60 seconds by
  default. Each named repo has its own Finch connection pool, which `:pools` configures with Finch's `:pools`
  option (`%{default: [size: 10, count: 2]}` by default). Repos started with `name: nil`, like dynamic repos, share
  the driver's pool. For calls outside Ecto, `client/1` returns the repo's `Turbopuffer.Client`. A failed request
  raises `TP.Error`.

  ## Namespaces

  A schema's source is its namespace. An Ecto prefix, from `@schema_prefix`, the `:prefix` option, or the repo's
  `default_options/1`, is prepended with a dash: `prefix: "staging"` reads and writes `staging-card_stacks`.

  ## Writes

  Writes that store values send the schema's `TP.Namespace` schema and distance metric, so a namespace is created
  or extended by its first write.

    * `insert` and `insert_all` upsert whole documents. Like Ecto's other adapters, they refuse to overwrite an
      existing id by default: `insert` returns a `unique_constraint(:id)` error, and `insert_all` writes the new ids
      and raises `TP.ConflictError` naming the rest. Pass `on_conflict: :nothing` to skip existing ids or
      `on_conflict: :replace_all` to overwrite them. turbopuffer can't replace only some fields of an existing
      document, so other `:on_conflict` values raise.
    * `insert_all` sends at most 30 rows per request for schemas with native embedding, turbopuffer's limit, and
      1,000 otherwise. Set `:batch_size` to change that. Batches aren't atomic.
    * `update` patches the changed fields. turbopuffer can't change ids, or patch vectors or the text it embeds
      natively, so changing one raises; upsert instead. `update` and `delete` raise `Ecto.StaleEntryError` when the
      id doesn't exist.
    * `update_all` (`set` only) and `delete_all` patch and delete by filter, up to turbopuffer's 50k and 5M
      document limits per call.

  ## Queries

  `Repo.all`, `one`, `get`, `exists?`, `aggregate` and `stream` work, with these limits:

    * turbopuffer returns at most 10,000 rows per query, and `limit + offset` can't exceed that. Queries ordered
      by id, or not ordered, page through everything when there's no limit; any other ordering needs a limit.
    * `order_by` takes either up to 8 fields or one search from `TP.Query`, not both.
    * Aggregations support `count()` and `sum/1`. With `group_by`, they need a limit, since turbopuffer returns
      at most 10,000 groups.
    * `union_all` sends the queries together as one multi-query against one namespace, each keeping its own
      ranking and limit, and returns their rows one after another. The first query's `order_by` and `limit` are
      its own, not the union's. Pass `rerank_by: :rrf` (or `{:rrf, weights: [2, 1], rank_constant: 60, limit: 20,
      offset: 0}`) to have turbopuffer fuse them into one ranking with reciprocal rank fusion; then every query
      must select the same fields.
    * `consistency: :eventual` trades freshness for throughput. See `docs/turbopuffer/query.md#param-consistency`.
    * A namespace that hasn't been written to yet reads as empty.
    * No joins, subqueries, distinct, or having.

  Filters follow SQL's null semantics for ordering: `<`, `<=`, `>` and `>=` never match nil, even under `not`.
  `!=`, `not in`, and `not` around other filters do match nil, as turbopuffer's inverse operators do; add
  `not is_nil(field)` to exclude it.

  Every request emits the repo's `[..., :query]` telemetry event.
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Queryable

  alias Ecto.Adapters.Turbopuffer.Plan

  @client_options [:api_key, :region, :base_url, :max_retries, :retry_delay]
  @pools %{default: [size: 10, count: 2]}

  @doc "The `Turbopuffer.Client` behind a running repo, for calls outside Ecto."
  @spec client(Ecto.Repo.t() | pid() | atom()) :: Turbopuffer.Client.t()
  def client(repo), do: Ecto.Adapter.lookup_meta(repo).client

  @doc "The namespace `schema` reads and writes, under an optional Ecto prefix."
  @spec namespace(module(), String.t() | nil) :: String.t()
  def namespace(schema, prefix \\ nil) do
    TP.Namespace.name!(schema.__schema__(:source), prefix || schema.__schema__(:prefix))
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
    {finch, child} = pool(repo, Keyword.get(config, :name, repo), config)

    meta = %{
      client: config |> Keyword.take(@client_options) |> Keyword.put(:finch_name, finch) |> Turbopuffer.Client.new(),
      request_opts: [receive_timeout: Keyword.get(config, :receive_timeout, 60_000)],
      telemetry: {repo, Keyword.fetch!(config, :telemetry_prefix) ++ [:query]}
    }

    {:ok, child, meta}
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
    [plan] = Plan.upserts(schema_meta, [fields], on_conflict, nil)

    case write!(meta, plan, opts) do
      %{"rows_affected" => 1} -> {:ok, []}
      _ when elem(on_conflict, 0) == :raise -> {:invalid, [unique: "#{schema_meta.source}_id_index"]}
      _ -> {:ok, []}
    end
  end

  @impl Ecto.Adapter.Schema
  def insert_all(meta, schema_meta, _header, rows, on_conflict, returning, placeholders, opts) do
    no_returning!(returning)
    rows = Enum.map(rows, fn fields -> Enum.map(fields, &resolve_placeholder(&1, placeholders)) end)
    plans = Plan.upserts(schema_meta, rows, on_conflict, opts[:batch_size])
    responses = Enum.map(plans, &write!(meta, &1, opts))
    count = responses |> Enum.map(& &1["rows_affected"]) |> Enum.sum()

    if elem(on_conflict, 0) == :raise and count < length(rows) do
      written = MapSet.new(Enum.flat_map(responses, &Map.get(&1, "upserted_ids", [])))
      ids = for plan <- plans, %{"id" => id} <- plan.body["upsert_rows"], id not in written, do: id
      raise TP.ConflictError, namespace: hd(plans).namespace, ids: ids, count: length(rows)
    end

    {count, nil}
  end

  @impl Ecto.Adapter.Schema
  def update(meta, schema_meta, fields, filters, returning, opts) do
    no_returning!(returning)
    plan = Plan.update(schema_meta, fields, filters)
    if write!(meta, plan, opts)["rows_affected"] == 1, do: {:ok, []}, else: {:error, :stale}
  end

  @impl Ecto.Adapter.Schema
  def delete(meta, schema_meta, filters, returning, opts) do
    no_returning!(returning)
    plan = Plan.delete(schema_meta, filters)
    if write!(meta, plan, opts)["rows_affected"] == 1, do: {:ok, []}, else: {:error, :stale}
  end

  # ------------------------------------------------------------------------------------------------
  # Ecto.Adapter.Queryable
  # ------------------------------------------------------------------------------------------------

  @impl Ecto.Adapter.Queryable
  def prepare(operation, query), do: {:nocache, {operation, query}}

  @impl Ecto.Adapter.Queryable
  def execute(meta, _query_meta, {:nocache, {:all, query}}, params, opts) do
    rows = query |> Plan.all(params, opts) |> pages(meta, opts) |> Enum.concat()
    {length(rows), rows}
  end

  def execute(meta, _query_meta, {:nocache, {:update_all, query}}, params, opts) do
    {write!(meta, Plan.update_all(query, params), opts)["rows_affected"], nil}
  end

  def execute(meta, _query_meta, {:nocache, {:delete_all, query}}, params, opts) do
    {write!(meta, Plan.delete_all(query, params), opts)["rows_affected"], nil}
  end

  @impl Ecto.Adapter.Queryable
  def stream(meta, _query_meta, {:nocache, {:all, query}}, params, opts) do
    query |> Plan.all(params, opts) |> pages(meta, opts) |> Stream.map(&{length(&1), &1})
  end

  # ------------------------------------------------------------------------------------------------
  # PRIVATE
  # ------------------------------------------------------------------------------------------------

  # Finch names a pool's processes after atoms, so a repo started without a name shares the driver's pool rather
  # than creating atoms each time one starts. Ecto still needs a child to supervise, so it gets an empty supervisor.
  defp pool(_repo, name, config) when is_atom(name) and name != nil do
    finch = Module.concat(name, Finch)
    {finch, Finch.child_spec(name: finch, pools: Keyword.get(config, :pools, @pools))}
  end

  defp pool(repo, _name, config) do
    if Keyword.has_key?(config, :pools) do
      raise ArgumentError, "a repo started without a name shares the turbopuffer driver's pool, so it can't take :pools"
    end

    {Turbopuffer.Finch,
     %{id: {__MODULE__, repo}, start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}, type: :supervisor}}
  end

  defp pages(plan, meta, opts) do
    Stream.unfold(plan.body, fn
      nil ->
        nil

      body ->
        case request(meta, %{plan | body: body}, opts) do
          {:ok, response} -> Plan.page(plan, response)
          {:error, %TP.Error{status: 404}} -> Plan.empty_page(plan)
          {:error, error} -> raise error
        end
    end)
  end

  # Patches and deletes on a namespace that doesn't exist yet change nothing.
  defp write!(meta, plan, opts) do
    case request(meta, plan, opts) do
      {:ok, response} -> response
      {:error, %TP.Error{status: 404}} -> %{"rows_affected" => 0}
      {:error, error} -> raise error
    end
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

  defp request(%{client: client, telemetry: {repo, event}} = meta, plan, opts) do
    {kind, path} =
      case plan.kind do
        :write -> {:write, "/v2/namespaces/#{plan.namespace}"}
        _query -> {:query, "/v2/namespaces/#{plan.namespace}/query"}
      end

    start = System.monotonic_time()
    result = client |> Turbopuffer.Client.post(path, plan.body, meta.request_opts) |> result()

    :telemetry.execute(event, %{total_time: System.monotonic_time() - start}, %{
      type: :ecto_turbopuffer_query,
      repo: repo,
      kind: kind,
      source: plan.namespace,
      query: plan.body,
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
end
