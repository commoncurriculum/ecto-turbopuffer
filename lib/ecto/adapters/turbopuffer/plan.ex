defmodule Ecto.Adapters.Turbopuffer.Plan do
  @moduledoc false
  # Builds every request the adapter sends, from Ecto's queries and writes (docs/turbopuffer/query.md, write.md),
  # and reads query responses back into the selected rows. Expr compiles the expressions inside them.

  alias Ecto.Adapters.Turbopuffer.Expr

  require Ecto.Query

  @max_limit 10_000
  @max_queries 16
  @batch_size 1_000
  # turbopuffer's limit on documents per write for namespaces with native embedding.
  @embed_batch_size 30

  # `kind` is the request and how its response reads:
  #   * `:rows`, `:aggregate`, `:groups` - one query, whose rows `readers` read
  #   * `:multi` - a union_all's queries, each leg's rows read by its own readers
  #   * `:fused` - a union_all that rerank_by fuses into one list of rows
  #   * `:write`
  # `cursor` is `:asc` or `:desc` on a query read a page at a time by id.
  @enforce_keys [:kind, :namespace, :body]
  defstruct [:kind, :namespace, :body, readers: [], legs: [], cursor: nil]

  @doc """
  Plans a `Repo.all` query. A `union_all` becomes one multi-query, fused into one ranking when `opts` has
  `:rerank_by`. `:limit_per` caps the rows sharing values of some fields.
  """
  def all(query, params, opts) do
    rerank_by = Keyword.get(opts, :rerank_by)

    plan =
      case legs(query) do
        [_query] when rerank_by != nil ->
          raise ArgumentError, "rerank_by fuses the searches of a union_all, but this query has only one"

        [query] ->
          query |> plan(params) |> limit_per(query, Keyword.get(opts, :limit_per))

        legs ->
          if opts[:limit_per], do: raise(ArgumentError, "limit_per can't cap a union_all's rows")
          multi(query, Enum.map(legs, &plan(&1, params)), rerank_by)
      end

    %{plan | body: put(plan.body, "consistency", consistency(Keyword.get(opts, :consistency)))}
  end

  @doc """
  The body of a recall evaluation (docs/turbopuffer/recall.md): the query's filters, its vector search as the
  rank_by, and its limit as top_k, unless `opts` sets `:top_k` or `:num`.
  """
  def recall(query, params, opts) do
    ctx = context(query, params, :all)
    opts = Keyword.validate!(opts, [:num, :top_k, :prefix, :telemetry_options])
    rank_by = if query.order_bys != [], do: ctx |> Expr.rank_by() |> elem(0)

    %{}
    |> put("filters", filters(ctx, nil))
    |> put("rank_by", rank_by)
    |> put("top_k", opts[:top_k] || if(query.limit, do: limit(ctx)))
    |> put("num", opts[:num])
  end

  def update_all(query, params) do
    ctx = context(query, params, :update_all)

    fields =
      Enum.flat_map(query.updates, fn %{expr: expr} ->
        Enum.flat_map(expr, fn
          {:set, sets} -> Enum.map(sets, fn {field, value} -> {field, Expr.value(ctx, value)} end)
          {op, _} -> Expr.error!(query, "turbopuffer can only `set` fields in update_all, not #{op}")
        end)
      end)

    {params, patch} =
      case ctx.namespace do
        nil -> {%{}, Map.new(fields, fn {source, value} -> {Atom.to_string(source), value} end)}
        namespace -> {TP.Namespace.write_params(namespace), TP.Namespace.patch!(namespace, fields)}
      end

    body = Map.put(params, "patch_by_filter", %{"filters" => filters(ctx, Expr.everything()), "patch" => patch})
    %__MODULE__{kind: :write, namespace: name(query), body: body}
  end

  def delete_all(query, params) do
    ctx = context(query, params, :delete_all)
    %__MODULE__{kind: :write, namespace: name(query), body: %{"delete_by_filter" => filters(ctx, Expr.everything())}}
  end

  @doc """
  Upserts rows of dumped fields in batches, given Ecto's schema metadata. `on_conflict: :raise` and `:nothing`
  only insert new ids, and `:raise` has turbopuffer return the ids it wrote, so the adapter can name the ones it
  skipped. `opts` takes `:batch_size`, `:replace_if` and `:disable_backpressure`.
  """
  def upserts(%{schema: schema} = schema_meta, rows, on_conflict, opts) do
    namespace = TP.Namespace.new(schema || raise(ArgumentError, "turbopuffer writes need a schema for the types"))
    condition = upsert_condition!(namespace, on_conflict, opts[:replace_if])
    backpressure = disable_backpressure!(opts[:disable_backpressure], condition)
    params = TP.Namespace.write_params(namespace)
    name = name(schema_meta)

    rows
    |> Enum.map(&TP.Namespace.row!(namespace, &1))
    |> Enum.chunk_every(batch_size!(opts[:batch_size], namespace))
    |> Enum.map(fn batch ->
      body =
        params
        |> Map.put("upsert_rows", batch)
        |> put("upsert_condition", condition)
        |> put("return_affected_ids", if(elem(on_conflict, 0) == :raise, do: true))
        |> put("disable_backpressure", backpressure)

      %__MODULE__{kind: :write, namespace: name, body: body}
    end)
  end

  @doc "Patches one document's changed fields, given Ecto's filters: its id and any other fields to check."
  def update(%{schema: schema} = schema_meta, fields, filters) do
    namespace = TP.Namespace.new(schema)
    {id, condition} = id_and_condition(filters)

    body =
      namespace
      |> TP.Namespace.write_params()
      |> Map.put("patch_rows", [Map.put(TP.Namespace.patch!(namespace, fields), "id", id)])
      |> put("patch_condition", Expr.filter_json(condition, nil))

    %__MODULE__{kind: :write, namespace: name(schema_meta), body: body}
  end

  @doc """
  Deletes one document. The condition that it exists makes turbopuffer count a missing id as not deleted.
  """
  def delete(schema_meta, filters) do
    {id, condition} = id_and_condition(filters)
    body = %{"deletes" => [id], "delete_condition" => Expr.junction(:and, Expr.everything(), condition)}
    %__MODULE__{kind: :write, namespace: name(schema_meta), body: body}
  end

  @doc """
  The selected rows in a query response, and the body that fetches the next page, or `nil` when there isn't one.
  """
  def page(%__MODULE__{kind: :multi} = plan, %{"results" => results}) do
    rows = Enum.zip_with(plan.legs, results, fn leg, %{"rows" => rows} -> Enum.map(rows, &read(leg.readers, &1)) end)
    {Enum.concat(rows), nil}
  end

  def page(%__MODULE__{} = plan, response) do
    rows = response_rows(plan.kind, response)
    {Enum.map(rows, &read(plan.readers, &1)), next_page(plan, rows)}
  end

  @doc "The page a namespace that doesn't exist yet reads as: no rows, or aggregations of nothing."
  def empty_page(%__MODULE__{kind: :aggregate} = plan), do: page(plan, %{"aggregations" => %{}})
  def empty_page(_plan), do: {[], nil}

  # ------------------------------------------------------------------------------------------------
  # queries
  # ------------------------------------------------------------------------------------------------

  # Ecto nests `union_all(a, ^union_all(b, ^c))` as a tree, and turbopuffer takes a flat list of queries. The
  # first leg keeps the parent query's own ordering and limit.
  defp legs(query) do
    legs =
      Enum.flat_map(query.combinations, fn
        {:union_all, leg} -> legs(leg)
        {kind, _leg} -> Expr.error!(query, "turbopuffer can only combine searches with union_all, not #{kind}")
      end)

    [%{query | combinations: []} | legs]
  end

  defp plan(query, params) do
    ctx = context(query, params, :all)
    if Enum.any?(query.select.fields, &aggregate?/1), do: aggregate(ctx), else: rows(ctx)
  end

  defp rows(%Expr{query: query} = ctx) do
    {readers, include, compute} = select(ctx, query.select.fields)
    {rank_by, cursor} = Expr.rank_by(ctx)
    limit = if query.limit, do: limit(ctx)
    offset = if query.offset, do: Expr.value(ctx, query.offset.expr)

    if message = window_error(limit, offset), do: Expr.error!(query, message)

    # Without a limit, a query ordered by id reads every page after the last one's final id.
    cursor = if limit == nil and offset == nil, do: cursor

    if limit == nil and cursor == nil do
      Expr.error!(query, "turbopuffer returns at most #{@max_limit} results per query, so add a limit")
    end

    body =
      %{"rank_by" => rank_by, "limit" => limit || @max_limit}
      |> put("filters", filters(ctx, nil))
      |> put("offset", offset)
      |> put("include_attributes", if(include != [], do: include))
      |> put("compute_attributes", if(compute != %{}, do: compute))
      |> put("vector_encoding", if(Enum.any?(include, &vector?(ctx, &1)), do: "base64"))

    %__MODULE__{kind: :rows, namespace: name(query), body: body, readers: readers, cursor: cursor}
  end

  defp aggregate(%Expr{query: query} = ctx) do
    if query.order_bys != [], do: Expr.error!(query, "turbopuffer can't order aggregations")
    if query.offset, do: Expr.error!(query, "turbopuffer can't offset aggregations")

    group_by = for %{expr: exprs} <- query.group_bys, expr <- exprs, do: Expr.name!(ctx, expr, :filter)
    limit = if query.limit, do: limit(ctx)

    if message = window_error(limit, nil), do: Expr.error!(query, message)

    if group_by != [] and limit == nil do
      Expr.error!(query, "turbopuffer returns at most #{@max_limit} groups, so add a limit")
    end

    {readers, aggregates} =
      query.select.fields
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {field, index}, aggregates ->
        cond do
          aggregate?(field) ->
            label = "ecto_#{index}"
            {aggregate, empty} = aggregate!(ctx, field)
            {{:key, label, empty}, Map.put(aggregates, label, aggregate)}

          Expr.field?(field) and Expr.name!(ctx, field, nil) in group_by ->
            {{:key, Expr.name!(ctx, field, nil), nil}, aggregates}

          true ->
            Expr.error!(query, "select only aggregates and group_by fields in a turbopuffer aggregation")
        end
      end)

    body =
      %{"aggregate_by" => aggregates}
      |> put("filters", filters(ctx, nil))
      |> put("group_by", if(group_by != [], do: group_by))
      # Aggregations reject `limit`, though the docs call top_k its alias.
      |> put("top_k", if(group_by != [], do: limit))

    kind = if group_by == [], do: :aggregate, else: :groups
    %__MODULE__{kind: kind, namespace: name(query), body: body, readers: readers}
  end

  defp multi(query, legs, rerank_by) do
    for leg <- legs do
      cond do
        leg.kind != :rows -> Expr.error!(query, "turbopuffer can't combine aggregations with union_all")
        leg.cursor -> Expr.error!(query, "each search in a union_all needs a limit")
        true -> :ok
      end
    end

    if length(legs) > @max_queries do
      Expr.error!(query, "turbopuffer runs at most #{@max_queries} queries in a union_all")
    end

    namespace =
      case legs |> Enum.map(& &1.namespace) |> Enum.uniq() do
        [namespace] -> namespace
        namespaces -> Expr.error!(query, "a union_all runs against one namespace, not #{Enum.join(namespaces, ", ")}")
      end

    # turbopuffer takes vector_encoding on the multi-query, not its queries.
    encoding = Enum.find_value(legs, & &1.body["vector_encoding"])
    queries = Enum.map(legs, &Map.delete(&1.body, "vector_encoding"))
    body = %{"queries" => queries} |> put("vector_encoding", encoding) |> Map.merge(rerank(rerank_by, length(legs)))

    if rerank_by do
      [%{readers: readers} | _] = legs

      unless Enum.all?(legs, &(&1.readers == readers)) do
        Expr.error!(query, "rerank_by fuses the searches into one list of rows, so they must select the same fields")
      end

      %__MODULE__{kind: :fused, namespace: namespace, body: body, readers: readers, legs: legs}
    else
      %__MODULE__{kind: :multi, namespace: namespace, body: body, legs: legs}
    end
  end

  defp rerank(nil, _count), do: %{}
  defp rerank(:rrf, count), do: rerank({:rrf, []}, count)

  # turbopuffer takes one weight above 0 per query, and a rank constant that's an integer above 0.
  defp rerank({:rrf, opts}, count) when is_list(opts) do
    opts = Keyword.validate!(opts, [:rank_constant, :weights, :limit, :offset])
    weights = opts[:weights]
    rank_constant = opts[:rank_constant]

    cond do
      weights != nil and not (is_list(weights) and length(weights) == count and Enum.all?(weights, &positive?/1)) ->
        raise ArgumentError,
              "rerank_by needs a weight above 0 for each of the #{count} searches, got: #{inspect(weights)}"

      rank_constant != nil and not (is_integer(rank_constant) and rank_constant > 0) ->
        raise ArgumentError, "rerank_by's rank_constant must be an integer above 0, got: #{inspect(rank_constant)}"

      message = window_error(opts[:limit], opts[:offset]) ->
        raise ArgumentError, "rerank_by: " <> message

      true ->
        :ok
    end

    params = for {key, value} <- opts, key in [:rank_constant, :weights], into: %{}, do: {Atom.to_string(key), value}

    %{"rerank_by" => if(params == %{}, do: ["RRF"], else: ["RRF", params])}
    |> put("limit", opts[:limit])
    |> put("offset", opts[:offset])
  end

  defp rerank(other, _count) do
    raise ArgumentError, "unknown :rerank_by #{inspect(other)}, expected :rrf or {:rrf, opts}"
  end

  defp positive?(number), do: is_number(number) and number > 0

  defp consistency(nil), do: nil
  defp consistency(level) when level in [:strong, :eventual], do: %{"level" => Atom.to_string(level)}

  defp consistency(other) do
    raise ArgumentError, ":consistency must be :strong or :eventual, got: #{inspect(other)}"
  end

  defp context(query, params, operation) do
    check!(query, operation)
    {_source, schema, _prefix} = elem(query.sources, 0)
    %Expr{query: query, params: params, namespace: schema && TP.Namespace.new(schema)}
  end

  # The namespace a query or a write's schema metadata reads and writes.
  defp name(%Ecto.Query{sources: sources}) do
    {source, _schema, prefix} = elem(sources, 0)
    TP.Namespace.name!(source, prefix)
  end

  defp name(%{source: source, prefix: prefix}), do: TP.Namespace.name!(source, prefix)

  defp check!(query, operation) do
    cond do
      query.joins != [] ->
        Expr.error!(query, "turbopuffer has no joins")

      query.distinct ->
        Expr.error!(query, "turbopuffer has no distinct")

      query.havings != [] ->
        Expr.error!(query, "turbopuffer has no having")

      query.windows != [] ->
        Expr.error!(query, "turbopuffer has no windows")

      query.lock ->
        Expr.error!(query, "turbopuffer has no locks")

      query.with_ctes ->
        Expr.error!(query, "turbopuffer has no CTEs")

      not match?({source, _} when is_binary(source), query.from.source) ->
        Expr.error!(query, "turbopuffer has no subqueries")

      operation != :all and query.select ->
        Expr.error!(query, "turbopuffer's #{operation} can't return rows")

      operation == :all and query.group_bys != [] and not Enum.any?(query.select.fields, &aggregate?/1) ->
        Expr.error!(query, "group_by needs an aggregate")

      true ->
        :ok
    end
  end

  defp filters(ctx, every), do: ctx |> Expr.filters() |> Expr.filter_json(every)

  defp limit(%Expr{query: %{limit: %{with_ties: true}} = query}),
    do: Expr.error!(query, "turbopuffer has no limits with ties")

  defp limit(%Expr{query: %{limit: %{expr: expr}}} = ctx), do: Expr.value(ctx, expr)

  # turbopuffer returns at most 10,000 rows per query, however they're paged with offset.
  defp window_error(limit, offset) do
    cond do
      limit != nil and not (is_integer(limit) and limit in 1..@max_limit) ->
        "turbopuffer limits must be between 1 and #{@max_limit}, got: #{inspect(limit)}"

      offset != nil and not (is_integer(offset) and offset >= 0) ->
        "turbopuffer offsets must be integers of at least 0, got: #{inspect(offset)}"

      (limit || 0) + (offset || 0) > @max_limit ->
        "turbopuffer returns at most #{@max_limit} rows, so limit + offset can't exceed it, got: #{limit} + #{offset}"

      true ->
        nil
    end
  end

  defp select(ctx, fields) do
    {readers, {include, compute}} =
      fields
      |> Enum.with_index()
      |> Enum.map_reduce({[], %{}}, fn {field, index}, {include, compute} ->
        case Expr.selected(ctx, field) do
          {:attribute, "id"} ->
            {{:key, "id", nil}, {include, compute}}

          {:attribute, name} ->
            {{:key, name, nil}, {[name | include], compute}}

          :dist ->
            {{:key, "$dist", nil}, {include, compute}}

          {:compute, expr} ->
            label = "ecto_#{index}"
            {{:key, label, nil}, {include, Map.put(compute, label, expr)}}

          {:literal, value} ->
            {{:literal, value}, {include, compute}}
        end
      end)

    {readers, include |> Enum.reverse() |> Enum.uniq(), compute}
  end

  # Vectors read back smaller and faster as base64. Schemaless queries don't know which attributes are vectors.
  defp vector?(%Expr{namespace: nil}, _name), do: false
  defp vector?(%Expr{namespace: namespace}, name), do: TP.Types.vector?(namespace.by_name[name].type)

  defp aggregate?({agg, _, _}) when agg in [:count, :sum, :avg, :min, :max], do: true
  defp aggregate?(_field), do: false

  # An aggregation, and what it reads as over a namespace with no documents.
  defp aggregate!(_ctx, {:count, _, []}), do: {["Count"], 0}

  defp aggregate!(ctx, {:count, _, [field]} = expr) do
    if Expr.field?(field) and Expr.name!(ctx, field, nil) == "id" do
      {["Count"], 0}
    else
      Expr.error!(ctx, "turbopuffer counts documents, so use count() instead of #{Macro.to_string(expr)}")
    end
  end

  defp aggregate!(ctx, {:sum, _, [field]}), do: {["Sum", Expr.name!(ctx, field, nil)], nil}
  defp aggregate!(ctx, expr), do: Expr.error!(ctx, "turbopuffer can't aggregate #{Macro.to_string(expr)}")

  defp response_rows(:rows, %{"rows" => rows}), do: rows
  defp response_rows(:aggregate, %{"aggregations" => aggregations}), do: [aggregations]
  defp response_rows(:groups, %{"aggregation_groups" => groups}), do: groups
  # RRF returns one fused list of rows as the multi-query's only result.
  defp response_rows(:fused, %{"results" => results}), do: Enum.flat_map(results, & &1["rows"])

  defp read(readers, row) do
    Enum.map(readers, fn
      {:key, key, default} -> Map.get(row, key, default)
      {:literal, value} -> value
    end)
  end

  # Pages restart from the plan's own body, so each one filters past the previous page's last id.
  defp next_page(%{cursor: cursor, body: body}, rows) when cursor != nil and length(rows) == @max_limit do
    after_last = ["id", if(cursor == :asc, do: "Gt", else: "Lt"), List.last(rows)["id"]]
    Map.update(body, "filters", after_last, &Expr.junction(:and, &1, after_last))
  end

  defp next_page(_plan, _rows), do: nil

  # ------------------------------------------------------------------------------------------------
  # writes
  # ------------------------------------------------------------------------------------------------

  defp batch_size!(nil, namespace), do: if(namespace.embeds?, do: @embed_batch_size, else: @batch_size)
  defp batch_size!(size, _namespace) when is_integer(size) and size > 0, do: size

  defp batch_size!(size, _namespace) do
    raise ArgumentError, ":batch_size must be an integer above 0, got: #{inspect(size)}"
  end

  defp upsert_condition!(_namespace, {mode, _, _}, nil) when mode in [:raise, :nothing], do: Expr.nothing()

  defp upsert_condition!(_namespace, {mode, _, _}, _replace_if) when mode in [:raise, :nothing] do
    raise ArgumentError,
          ":replace_if decides when to replace an existing document, so it needs on_conflict: :replace_all"
  end

  defp upsert_condition!(namespace, {fields, _, _}, replace_if) when is_list(fields) do
    replaced = Enum.map(fields, &Atom.to_string/1)

    case for(%{primary_key: false, name: name} <- namespace.attributes, do: name) -- replaced do
      [] ->
        replace_if && replace_if!(namespace, replace_if)

      missing ->
        raise ArgumentError,
              "turbopuffer upserts replace whole documents, so on_conflict must replace every field, " <>
                "e.g. :replace_all. It leaves out #{inspect(missing)}."
    end
  end

  defp upsert_condition!(_namespace, _on_conflict, _replace_if) do
    raise ArgumentError, "turbopuffer can't run an update on conflict; use :replace_all, :nothing, or :raise"
  end

  # The filter an existing document must match to be replaced, where ref_new(field) is the value being written.
  defp replace_if!(namespace, replace_if) do
    query =
      case replace_if do
        %Ecto.Query.DynamicExpr{} -> Ecto.Query.where(namespace.module, ^replace_if)
        %Ecto.Query{} -> replace_if
        other -> raise ArgumentError, ":replace_if must be a dynamic or a query, got: #{inspect(other)}"
      end

    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.Turbopuffer, query)
    ctx = %Expr{query: query, params: params, namespace: namespace, condition: true}
    ctx |> Expr.filters() |> Expr.filter_json(nil)
  end

  # turbopuffer only skips backpressure for writes that don't read existing documents first.
  defp disable_backpressure!(nil, _condition), do: nil
  defp disable_backpressure!(false, _condition), do: nil
  defp disable_backpressure!(true, nil), do: true

  defp disable_backpressure!(true, _condition) do
    raise ArgumentError,
          "turbopuffer can't disable backpressure for conditional writes, so pass on_conflict: :replace_all " <>
            "without :replace_if"
  end

  defp disable_backpressure!(other, _condition) do
    raise ArgumentError, ":disable_backpressure must be a boolean, got: #{inspect(other)}"
  end

  # turbopuffer's limit.per, which needs a limit: capping rows per page wouldn't cap them overall.
  defp limit_per(plan, _query, nil), do: plan

  defp limit_per(%{kind: :rows, cursor: nil} = plan, query, {fields, limit})
       when is_list(fields) and fields != [] and is_integer(limit) and limit > 0 do
    {source, schema, _prefix} = elem(query.sources, 0)
    names = Enum.map(fields, &per_attribute!(query, schema, source, &1))

    %{
      plan
      | body: Map.update!(plan.body, "limit", &%{"total" => &1, "per" => %{"attributes" => names, "limit" => limit}})
    }
  end

  defp limit_per(%{kind: :rows, cursor: nil}, _query, other) do
    raise ArgumentError, ":limit_per must be {fields, limit}, like {[:planbook_id], 2}, got: #{inspect(other)}"
  end

  defp limit_per(%{kind: :rows}, query, _limit_per), do: Expr.error!(query, "limit_per needs a query with a limit")
  defp limit_per(_plan, query, _limit_per), do: Expr.error!(query, "limit_per caps rows, not aggregations")

  defp per_attribute!(_query, nil, _source, field) when is_atom(field), do: Atom.to_string(field)

  defp per_attribute!(query, schema, _source, field) when is_atom(field) do
    namespace = TP.Namespace.new(schema)

    case Enum.find(namespace.attributes, &(&1.field == field)) do
      nil ->
        Expr.error!(query, "#{inspect(schema)} has no field #{inspect(field)} for limit_per")

      attribute ->
        if message = TP.Attribute.missing(attribute, :filter), do: Expr.error!(query, message), else: attribute.name
    end
  end

  defp per_attribute!(query, _schema, _source, field),
    do: Expr.error!(query, "limit_per takes field names, got: #{inspect(field)}")

  defp id_and_condition(filters) do
    {id, others} = Keyword.pop!(filters, :id)

    condition =
      Enum.reduce(others, true, fn {source, value}, condition ->
        Expr.junction(:and, condition, [Atom.to_string(source), "Eq", value])
      end)

    {id, condition}
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
