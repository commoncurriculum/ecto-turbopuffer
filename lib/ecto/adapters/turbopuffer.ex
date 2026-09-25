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

  The functions below cover turbopuffer's namespace endpoints. Each takes the repo and a schema, and `:prefix` like a
  query; each raises `TP.Error` when turbopuffer returns an error, including 404 for a namespace nothing has been
  written to yet.

  ## Writes

  Writes that store values send the schema's `TP.Namespace` schema and distance metric, so a namespace is created
  or extended by its first write.

    * `insert` and `insert_all` upsert whole documents. Like Ecto's other adapters, they refuse to overwrite an
      existing id by default: `insert` returns a `unique_constraint(:id)` error, and `insert_all` writes the new ids
      and raises `TP.ConflictError` naming the rest. Pass `on_conflict: :nothing` to skip existing ids or
      `on_conflict: :replace_all` to overwrite them. turbopuffer can't replace only some fields of an existing
      document, so other `:on_conflict` values raise.
    * With `on_conflict: :replace_all`, `replace_if:` takes a dynamic an existing document must match to be
      replaced, where `ref_new(field)` is the value being written: `dynamic([c], c.updated_at < ref_new(c.updated_at))`
      only replaces older documents. Ids that don't exist yet are written either way.
    * `disable_backpressure: true` skips the 429s turbopuffer returns while unindexed writes pile up, for bulk loads
      with `on_conflict: :replace_all`. Strongly consistent queries fail until indexing catches up, so query with
      `consistency: :eventual` meanwhile. See `docs/turbopuffer/write.md#param-disable_backpressure`.
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
    * `limit_per: {[:planbook_id], 2}` returns at most 2 rows per planbook, for more varied results. The query
      needs a limit.
    * `consistency: :eventual` trades freshness for throughput. See `docs/turbopuffer/query.md#param-consistency`.
    * Queries that select vector fields read them as base64, which is smaller and faster to decode.
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
  def client(repo), do: meta(repo).client

  @doc "The namespace `schema` reads and writes, under an optional Ecto prefix."
  @spec namespace(module(), String.t() | nil) :: String.t()
  def namespace(schema, prefix \\ nil) do
    TP.Namespace.name!(schema.__schema__(:source), prefix || schema.__schema__(:prefix))
  end

  @doc """
  turbopuffer's metadata for a schema's namespace (`docs/turbopuffer/metadata.md`), like its `"schema"`,
  `"approx_row_count"`, `"index"` status, and `"read_only"`, `"sharding"`, `"pinning"` and `"branching"` when set.
  """
  @spec metadata(Ecto.Repo.t(), module(), keyword()) :: map()
  def metadata(repo, schema, opts \\ []) do
    namespace_request!(repo, schema, opts, :metadata, :get, "/v1/namespaces/:namespace/metadata", nil)
  end

  @doc """
  Changes a namespace's metadata and returns the result: `read_only: true` rejects writes until it's `false` again,
  and `pinning: [replicas: n]` reserves compute for the namespace until `pinning: nil`. Pinning is billed by the
  hour; see `docs/turbopuffer/pinning.md`.
  """
  @spec update_metadata(Ecto.Repo.t(), module(), keyword(), keyword()) :: map()
  def update_metadata(repo, schema, changes, opts \\ []) do
    body =
      changes
      |> Keyword.validate!([:read_only, :pinning])
      |> Map.new(fn
        {:read_only, read_only} when is_boolean(read_only) -> {"read_only", read_only}
        {:pinning, nil} -> {"pinning", nil}
        {:pinning, pinning} when is_list(pinning) -> {"pinning", Map.new(Keyword.validate!(pinning, [:replicas]))}
        {key, value} -> raise ArgumentError, "invalid #{inspect(key)}: #{inspect(value)}"
      end)

    namespace_request!(repo, schema, opts, :update_metadata, :patch, "/v1/namespaces/:namespace/metadata", body)
  end

  @doc """
  Tells turbopuffer queries to a schema's namespace are coming, so it can warm its cache
  (`docs/turbopuffer/warm-cache.md`).
  """
  @spec warm_cache(Ecto.Repo.t(), module(), keyword()) :: :ok
  def warm_cache(repo, schema, opts \\ []) do
    namespace_request!(repo, schema, opts, :warm_cache, :get, "/v1/namespaces/:namespace/hint_cache_warm", nil)
    :ok
  end

  @doc "Deletes a schema's namespace and all of its documents. There's no undoing it."
  @spec delete_namespace(Ecto.Repo.t(), module(), keyword()) :: :ok
  def delete_namespace(repo, schema, opts \\ []) do
    namespace_request!(repo, schema, opts, :delete_namespace, :delete, "/v2/namespaces/:namespace", nil)
    :ok
  end

  @doc """
  Declares a schema's turbopuffer schema on its existing namespace without writing documents, e.g. after adding
  `full_text_search:` or `embed:` to a field. Indexes build in the background, and queries needing one get a 409
  until it's ready. See `docs/turbopuffer/write.md#updating-attributes`.
  """
  @spec update_schema(Ecto.Repo.t(), module(), keyword()) :: :ok
  def update_schema(repo, schema, opts \\ []) do
    body = schema |> TP.Namespace.new() |> TP.Namespace.write_params()
    namespace_request!(repo, schema, opts, :update_schema, :post, "/v2/namespaces/:namespace", body)
    :ok
  end

  @doc """
  Makes a schema's namespace an instant copy-on-write branch of the namespace named `from`, which is left as it
  is. The namespace must be empty. See `docs/turbopuffer/branching.md`.

      Ecto.Adapters.Turbopuffer.branch(Repo, CardStack, from: Ecto.Adapters.Turbopuffer.namespace(CardStack, "prod"),
        prefix: "dev")
  """
  @spec branch(Ecto.Repo.t(), module(), keyword()) :: :ok
  def branch(repo, schema, opts) do
    {from, opts} = Keyword.pop!(opts, :from)
    body = %{"branch_from_namespace" => from}
    namespace_request!(repo, schema, opts, :branch, :post, "/v2/namespaces/:namespace", body)
    :ok
  end

  @doc """
  Copies every document of the namespace named `from` into a schema's empty namespace, server side. Pass
  `:from_region` and `:from_api_key` to copy from another region or organization. The copy keeps the source's
  sharding unless the schema sets `num_shards`. See `docs/turbopuffer/write.md#param-copy_from_namespace`.
  """
  @spec copy(Ecto.Repo.t(), module(), keyword()) :: :ok
  def copy(repo, schema, opts) do
    {from, opts} = Keyword.pop!(opts, :from)
    {source, opts} = Keyword.split(opts, [:from_region, :from_api_key])

    from =
      if source == [] do
        from
      else
        %{"source_namespace" => from}
        |> put("source_region", source[:from_region])
        |> put("source_api_key", source[:from_api_key])
      end

    body =
      %{"copy_from_namespace" => from}
      |> put("sharding", Map.get(TP.Namespace.write_params(TP.Namespace.new(schema)), "sharding"))

    namespace_request!(repo, schema, opts, :copy, :post, "/v2/namespaces/:namespace", body)
    :ok
  end

  @doc """
  The names of the namespaces starting with `:prefix`, which is turbopuffer's name prefix rather than an Ecto prefix.
  """
  @spec list_namespaces(Ecto.Repo.t(), keyword()) :: [String.t()]
  def list_namespaces(repo, opts \\ []) do
    opts = Keyword.validate!(opts, [:prefix, :page_size])
    meta = meta(repo)

    Stream.unfold(:first, fn
      nil ->
        nil

      cursor ->
        query =
          %{"prefix" => opts[:prefix], "page_size" => opts[:page_size], "cursor" => if(cursor != :first, do: cursor)}
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> URI.encode_query()

        path = "/v1/namespaces" <> if(query == "", do: "", else: "?" <> query)
        page = request!(meta, :get, path, nil, [], :list_namespaces, nil)
        {Enum.map(page["namespaces"], & &1["id"]), page["next_cursor"]}
    end)
    |> Enum.concat()
  end

  @doc """
  Measures the recall of a namespace's vector index (`docs/turbopuffer/recall.md`), returning `"avg_recall"`,
  `"avg_ann_count"` and `"avg_exhaustive_count"`: turbopuffer searches for `:num` random documents' vectors (25 by
  default), comparing its index's top `:top_k` (10 by default) to an exact search. Given a query, the searches
  keep to its `where`, and its `limit` is the top_k.

      Ecto.Adapters.Turbopuffer.recall(Repo, from(c in CardStack, where: c.planbook_id == ^id, limit: 10), num: 5)

  turbopuffer's docs say recall can also measure a given search (`rank_by`), but it answers one with a 404 for a
  namespace that exists, so a query with an `order_by` raises.
  """
  @spec recall(Ecto.Repo.t(), Ecto.Queryable.t(), keyword()) :: map()
  def recall(repo, queryable, opts \\ []) do
    query = Ecto.Queryable.to_query(queryable)
    query = if prefix = prefix(repo, opts), do: Ecto.Query.put_query_prefix(query, prefix), else: query
    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(:all, __MODULE__, query)
    {source, _schema, prefix} = elem(query.sources, 0)
    namespace = TP.Namespace.name!(source, prefix)

    request!(
      meta(repo),
      :post,
      "/v1/namespaces/#{namespace}/_debug/recall",
      Plan.recall(query, params, opts),
      opts,
      :recall,
      namespace
    )
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
    [plan] = Plan.upserts(schema_meta, [fields], on_conflict, Keyword.delete(opts, :batch_size))

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
    plans = Plan.upserts(schema_meta, rows, on_conflict, opts)
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

  defp request(meta, plan, opts) do
    case plan.kind do
      :write -> request(meta, :post, "/v2/namespaces/#{plan.namespace}", plan.body, opts, :write, plan.namespace)
      _query -> request(meta, :post, "/v2/namespaces/#{plan.namespace}/query", plan.body, opts, :query, plan.namespace)
    end
  end

  defp request(%{client: client, telemetry: {repo, event}} = meta, method, path, body, opts, kind, namespace) do
    start = System.monotonic_time()
    result = client |> Turbopuffer.Client.request(method, path, body, meta.request_opts) |> result()

    :telemetry.execute(event, %{total_time: System.monotonic_time() - start}, %{
      type: :ecto_turbopuffer_query,
      repo: repo,
      kind: kind,
      source: namespace,
      query: redact(body),
      result: result,
      options: Keyword.get(opts, :telemetry_options, [])
    })

    result
  end

  # Telemetry handlers often log requests, so the API key a copy from another organization sends stays out of them.
  defp redact(%{"copy_from_namespace" => %{"source_api_key" => _} = from} = body),
    do: %{body | "copy_from_namespace" => %{from | "source_api_key" => "[REDACTED]"}}

  defp redact(body), do: body

  defp request!(meta, method, path, body, opts, kind, namespace) do
    case request(meta, method, path, body, opts, kind, namespace) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  defp namespace_request!(repo, schema, opts, kind, method, path, body) do
    opts = Keyword.validate!(opts, [:prefix, :telemetry_options])
    namespace = namespace(schema, prefix(repo, opts))
    request!(meta(repo), method, String.replace(path, ":namespace", namespace), body, opts, kind, namespace)
  end

  # Repo operations apply the repo's default_options/1, so these do too, as a query would.
  defp prefix(repo, opts) do
    Keyword.get_lazy(opts, :prefix, fn ->
      if is_atom(repo) and function_exported?(repo, :default_options, 1), do: repo.default_options(:all)[:prefix]
    end)
  end

  defp meta(repo) do
    repo = if is_atom(repo) and function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo(), else: repo
    Ecto.Adapter.lookup_meta(repo)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

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
