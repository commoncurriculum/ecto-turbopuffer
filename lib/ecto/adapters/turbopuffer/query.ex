defmodule Ecto.Adapters.Turbopuffer.Query do
  @moduledoc false
  # Translates planned Ecto queries into turbopuffer request bodies, and query responses back into the selected rows
  # (docs/turbopuffer/query.md, write.md).

  alias Ecto.Query.Tagged

  @max_limit 10_000
  @max_queries 16
  @every_document ["id", "NotEq", nil]

  # The TP.Query filters, and what each needs from its attribute.
  @filters %{
    "Fuzzy" => "fuzzy",
    "Regex" => "regex",
    "Glob" => "glob",
    "IGlob" => "glob",
    "ContainsAllTokens" => "full_text_search",
    "ContainsAnyToken" => "full_text_search",
    "ContainsTokenSequence" => "full_text_search",
    "Contains" => :filterable,
    "ContainsAny" => :filterable,
    "AnyLt" => :filterable,
    "AnyLte" => :filterable,
    "AnyGt" => :filterable,
    "AnyGte" => :filterable
  }

  # turbopuffer requires max_edit_distance, and each step's min_query_chars must be at least 3 * (distance + 1).
  @fuzzy_params %{
    "max_edit_distance" => [
      %{"min_query_chars" => 3, "distance" => 0},
      %{"min_query_chars" => 6, "distance" => 1},
      %{"min_query_chars" => 9, "distance" => 2}
    ]
  }

  # `paginate` marks a query with no limit, ordered by id, which is read a page at a time.
  defstruct [:namespace, :body, readers: [], paginate: false]

  @doc """
  Plans a `Repo.all` query. A `union_all` becomes one multi-query, fused into one ranking when `opts` has
  `:rerank_by`.
  """
  def all(query, params, opts) do
    plan =
      case [plan(query, params) | Enum.map(query.combinations, &combination!(query, &1, params))] do
        [plan] -> plan
        plans -> multi(query, plans, opts)
      end

    %{plan | body: put(plan.body, "consistency", consistency(Keyword.get(opts, :consistency)))}
  end

  def delete_all(query, params) do
    ctx = context(query, params, :delete_all)
    %__MODULE__{namespace: ctx.namespace, body: %{"delete_by_filter" => filters(ctx) || @every_document}}
  end

  def update_all(query, params) do
    ctx = context(query, params, :update_all)

    patch =
      query.updates
      |> Enum.flat_map(& &1.expr)
      |> Enum.flat_map(fn
        {:set, sets} -> Enum.map(sets, fn {field, value} -> {patch_name!(ctx, field), value(value, ctx)} end)
        {op, _} -> error!(query, "turbopuffer can only `set` fields in update_all, not #{op}")
      end)
      |> Map.new()

    body = %{"patch_by_filter" => %{"filters" => filters(ctx) || @every_document, "patch" => patch}}
    %__MODULE__{namespace: ctx.namespace, body: body}
  end

  @doc """
  The selected rows in a query response, and the body that fetches the next page, or `nil` when there isn't one.
  """
  def page(%__MODULE__{} = plan, response) do
    rows = response_rows(response)
    {Enum.map(rows, &read(plan.readers, &1)), next_page(plan, rows)}
  end

  @doc "The page a namespace that doesn't exist yet reads as: no rows, or empty aggregations."
  def empty_page(%__MODULE__{body: %{"aggregate_by" => aggregates} = body} = plan)
      when not is_map_key(body, "group_by") do
    empty = Map.new(aggregates, fn {label, [function | _]} -> {label, if(function == "Count", do: 0)} end)
    page(plan, %{"aggregations" => empty})
  end

  def empty_page(_plan), do: {[], nil}

  @doc "The turbopuffer namespace for an Ecto source and prefix."
  def namespace(source, prefix) do
    namespace = if prefix, do: "#{prefix}-#{source}", else: source

    if namespace =~ ~r/\A[A-Za-z0-9\-_.]{1,128}\z/ do
      namespace
    else
      raise ArgumentError, "turbopuffer namespace names must match [A-Za-z0-9-_.]{1,128}, got: #{inspect(namespace)}"
    end
  end

  # turbopuffer's response says which kind of query it answers.
  defp response_rows(%{"results" => results}), do: Enum.flat_map(results, & &1["rows"])
  defp response_rows(%{"aggregation_groups" => groups}), do: groups
  defp response_rows(%{"aggregations" => aggregations}), do: [aggregations]
  defp response_rows(%{"rows" => rows}), do: rows

  defp read(readers, row) do
    Enum.map(readers, fn
      {:key, key} -> Map.get(row, key)
      {:literal, value} -> value
    end)
  end

  # Pages restart from the plan's own body, so each one filters past the previous page's last id.
  defp next_page(%{paginate: true, body: body}, rows) when length(rows) == @max_limit do
    ["id", direction] = body["rank_by"]
    after_last = ["id", if(direction == "asc", do: "Gt", else: "Lt"), List.last(rows)["id"]]
    Map.update(body, "filters", after_last, &["And", [&1, after_last]])
  end

  defp next_page(_plan, _rows), do: nil

  defp combination!(_query, {:union_all, subquery}, params), do: plan(subquery, params)

  defp combination!(query, {kind, _}, _params) do
    error!(query, "turbopuffer can only combine searches with union_all, not #{kind}")
  end

  defp plan(query, params) do
    ctx = context(query, params, :all)
    if aggregates?(query), do: plan_aggregate(ctx), else: plan_rows(ctx)
  end

  defp plan_rows(%{query: query} = ctx) do
    {readers, include, compute} = select(ctx, query.select.fields)
    rank_by = rank_by(ctx)
    limit = limit(ctx)
    offset = if query.offset, do: value(query.offset.expr, ctx)
    paginate = limit == nil and offset == nil and match?(["id", _], rank_by)

    if limit == nil and not paginate do
      error!(query, "turbopuffer returns at most #{@max_limit} results per query, so add a limit")
    end

    body =
      %{"rank_by" => rank_by, "limit" => limit || @max_limit}
      |> put("filters", filters(ctx))
      |> put("offset", offset)
      |> put("include_attributes", if(include != [], do: include))
      |> put("compute_attributes", if(compute != %{}, do: compute))

    %__MODULE__{namespace: ctx.namespace, body: body, readers: readers, paginate: paginate}
  end

  defp plan_aggregate(%{query: query} = ctx) do
    if query.order_bys != [], do: error!(query, "turbopuffer can't order aggregations")
    if query.offset, do: error!(query, "turbopuffer can't offset aggregations")

    group_by =
      for %{expr: exprs} <- query.group_bys, expr <- exprs do
        attribute_name!(ctx, expr, :filterable)
      end

    {readers, aggregates} =
      query.select.fields
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {field, index}, aggregates ->
        cond do
          aggregate?(field) ->
            label = "ecto_#{index}"
            {{:key, label}, Map.put(aggregates, label, aggregate!(ctx, field))}

          field?(field) and attribute_name!(ctx, field, :any) in group_by ->
            {{:key, attribute_name!(ctx, field, :any)}, aggregates}

          true ->
            error!(query, "select only aggregates and group_by fields in a turbopuffer aggregation")
        end
      end)

    body =
      %{"aggregate_by" => aggregates}
      |> put("filters", filters(ctx))
      |> put("group_by", if(group_by != [], do: group_by))
      |> put("top_k", if(group_by != [], do: limit(ctx) || @max_limit))

    %__MODULE__{namespace: ctx.namespace, body: body, readers: readers}
  end

  defp multi(query, plans, opts) do
    queries =
      Enum.map(plans, fn
        %{paginate: true} -> error!(query, "each search in a union_all needs a limit")
        %{body: %{"aggregate_by" => _}} -> error!(query, "turbopuffer can't combine aggregations with union_all")
        plan -> plan.body
      end)

    if length(queries) > @max_queries do
      error!(query, "turbopuffer runs at most #{@max_queries} queries in a union_all")
    end

    %{hd(plans) | body: Map.merge(%{"queries" => queries}, rerank_by(Keyword.get(opts, :rerank_by)))}
  end

  defp rerank_by(nil), do: %{}
  defp rerank_by(:rrf), do: %{"rerank_by" => ["RRF"]}

  defp rerank_by({:rrf, opts}) do
    opts = Keyword.validate!(opts, [:rank_constant, :weights, :limit, :offset])
    params = opts |> Keyword.take([:rank_constant, :weights]) |> options()

    %{"rerank_by" => if(params == %{}, do: ["RRF"], else: ["RRF", params])}
    |> put("limit", opts[:limit])
    |> put("offset", opts[:offset])
  end

  defp rerank_by(other) do
    raise ArgumentError, "unknown :rerank_by #{inspect(other)}, expected :rrf or {:rrf, opts}"
  end

  defp consistency(nil), do: nil
  defp consistency(level) when level in [:strong, :eventual], do: %{"level" => Atom.to_string(level)}

  defp consistency(other) do
    raise ArgumentError, ":consistency must be :strong or :eventual, got: #{inspect(other)}"
  end

  defp context(query, params, operation) do
    check!(query, operation)
    {source, schema, prefix} = elem(query.sources, 0)

    %{
      query: query,
      params: params,
      schema: schema,
      # Keyed by name, because the planner has already replaced field names with their sources.
      attributes: schema && Map.new(TP.attributes(schema), &{&1.name, &1}),
      namespace: namespace(source, prefix)
    }
  end

  defp check!(query, operation) do
    cond do
      query.joins != [] ->
        error!(query, "turbopuffer has no joins")

      query.distinct ->
        error!(query, "turbopuffer has no distinct")

      query.havings != [] ->
        error!(query, "turbopuffer has no having")

      query.windows != [] ->
        error!(query, "turbopuffer has no windows")

      query.lock ->
        error!(query, "turbopuffer has no locks")

      query.with_ctes ->
        error!(query, "turbopuffer has no CTEs")

      not match?({source, _} when is_binary(source), query.from.source) ->
        error!(query, "turbopuffer has no subqueries")

      operation != :all and query.order_bys != [] ->
        error!(query, "#{operation} can't be ordered")

      operation != :all and (query.limit || query.offset) ->
        error!(query, "#{operation} can't take a limit")

      operation != :all and query.select ->
        error!(query, "turbopuffer's #{operation} can't return rows")

      operation == :all and query.group_bys != [] and not aggregates?(query) ->
        error!(query, "group_by needs an aggregate")

      true ->
        :ok
    end
  end

  defp aggregates?(query), do: Enum.any?(query.select.fields, &aggregate?/1)

  defp limit(%{query: %{limit: nil}}), do: nil

  defp limit(%{query: %{limit: %{with_ties: true}} = query}),
    do: error!(query, "turbopuffer has no limits with ties")

  defp limit(%{query: %{limit: %{expr: expr}}} = ctx) do
    case value(expr, ctx) do
      limit when is_integer(limit) and limit in 1..@max_limit -> limit
      limit -> error!(ctx.query, "turbopuffer limits must be between 1 and #{@max_limit}, got: #{inspect(limit)}")
    end
  end

  # TP.Query's operators are fragments shaped like `Op(?, ?)`, read back here as `{op, args}`.
  defp call({:fragment, _, [raw: "$dist"]}), do: {"$dist", []}

  defp call({:fragment, _, [{:raw, open}, {:expr, arg} | rest]}) do
    if String.ends_with?(open, "("), do: call_args(String.trim_trailing(open, "("), rest, [arg])
  end

  defp call(_expr), do: nil

  defp call_args(op, [raw: ")"], args), do: {op, Enum.reverse(args)}
  defp call_args(op, [{:raw, ", "}, {:expr, arg} | rest], args), do: call_args(op, rest, [arg | args])
  defp call_args(_op, _parts, _args), do: nil

  # ------------------------------------------------------------------------------------------------
  # select
  # ------------------------------------------------------------------------------------------------

  defp select(ctx, fields) do
    {readers, {include, compute}} =
      fields
      |> Enum.with_index()
      |> Enum.map_reduce({[], %{}}, fn {field, index}, {include, compute} ->
        case selected(ctx, field) do
          {:attribute, "id"} ->
            {{:key, "id"}, {include, compute}}

          {:attribute, name} ->
            {{:key, name}, {[name | include], compute}}

          :dist ->
            {{:key, "$dist"}, {include, compute}}

          {:compute, expr} ->
            label = "ecto_#{index}"
            {{:key, label}, {include, Map.put(compute, label, expr)}}

          {:literal, value} ->
            {{:literal, value}, {include, compute}}
        end
      end)

    {readers, include |> Enum.reverse() |> Enum.uniq(), compute}
  end

  defp selected(ctx, expr) do
    cond do
      field?(expr) -> {:attribute, attribute_name!(ctx, expr, :any)}
      literal?(expr) -> {:literal, value(expr, ctx)}
      true -> selected_call(ctx, call(expr), expr)
    end
  end

  defp selected_call(_ctx, {"$dist", []}, _expr), do: :dist
  defp selected_call(ctx, {"BM25", _args}, expr), do: {:compute, score(ctx, expr)}

  defp selected_call(ctx, {"VectorDist", [field, vector]}, _expr) do
    {:compute, [attribute_name!(ctx, field, :vector), "VectorDist", vector_query(ctx, vector)]}
  end

  defp selected_call(ctx, _call, expr), do: error!(ctx.query, "turbopuffer can't select #{Macro.to_string(expr)}")

  defp aggregate?({agg, _, _}) when agg in [:count, :sum, :avg, :min, :max], do: true
  defp aggregate?(_field), do: false

  defp aggregate!(_ctx, {:count, _, []}), do: ["Count"]

  defp aggregate!(ctx, {:count, _, [field]} = expr) do
    if attribute_name!(ctx, field, :any) == "id" do
      ["Count"]
    else
      error!(ctx.query, "turbopuffer counts documents, so use count() instead of #{Macro.to_string(expr)}")
    end
  end

  defp aggregate!(ctx, {:sum, _, [field]}), do: ["Sum", attribute_name!(ctx, field, :any)]
  defp aggregate!(ctx, expr), do: error!(ctx.query, "turbopuffer can't aggregate #{Macro.to_string(expr)}")

  # ------------------------------------------------------------------------------------------------
  # order_by
  # ------------------------------------------------------------------------------------------------

  defp rank_by(%{query: %{order_bys: order_bys}} = ctx) do
    case Enum.flat_map(order_bys, & &1.expr) do
      [] ->
        ["id", "asc"]

      [{direction, expr}] ->
        if field?(expr), do: order(ctx, direction, expr), else: search(ctx, direction, expr)

      orders when length(orders) > 8 ->
        error!(ctx.query, "turbopuffer orders by at most 8 attributes")

      orders ->
        Enum.map(orders, fn {direction, expr} ->
          unless field?(expr), do: error!(ctx.query, "turbopuffer can't combine a search with other orderings")
          order(ctx, direction, expr)
        end)
    end
  end

  defp order(ctx, direction, field), do: [attribute_name!(ctx, field, :filterable), direction!(ctx, direction)]

  defp direction!(_ctx, direction) when direction in [:asc, :asc_nulls_first], do: "asc"
  defp direction!(_ctx, direction) when direction in [:desc, :desc_nulls_last], do: "desc"

  defp direction!(ctx, direction) do
    error!(ctx.query, "turbopuffer sorts nulls first ascending and last descending, so it can't order #{direction}")
  end

  defp search(ctx, direction, expr) do
    rank = score(ctx, expr)
    check_score_direction!(ctx, rank, direction)
    rank
  end

  defp check_score_direction!(ctx, [_, op, _ | _], direction) when op in ["ANN", "kNN"] do
    unless direction in [:asc, :asc_nulls_first] do
      error!(ctx.query, "#{op} ranks the closest vectors first, so order it asc")
    end
  end

  defp check_score_direction!(ctx, _rank, direction) do
    unless direction in [:desc, :desc_nulls_last] do
      error!(ctx.query, "turbopuffer ranks the highest scores first, so order it desc")
    end
  end

  defp score(ctx, {:+, _, [left, right]}), do: combine("Sum", score(ctx, left), score(ctx, right))

  defp score(ctx, {:*, _, [left, right]}) do
    cond do
      literal?(left) -> ["Product", value(left, ctx), score(ctx, right)]
      literal?(right) -> ["Product", value(right, ctx), score(ctx, left)]
      true -> error!(ctx.query, "turbopuffer can only multiply a score by a number")
    end
  end

  defp score(ctx, expr), do: score_call(ctx, call(expr), expr)

  defp score_call(ctx, {"Max", [left, right]}, _expr), do: combine("Max", score(ctx, left), score(ctx, right))

  defp score_call(ctx, {"BM25", [field, text | params]}, _expr) when length(params) <= 1 do
    [attribute_name!(ctx, field, "full_text_search"), "BM25", value(text, ctx) | options(params, ctx)]
  end

  defp score_call(ctx, {op, [field, vector]}, _expr) when op in ["ANN", "kNN"] do
    query = vector_query(ctx, vector)
    need = if match?(["Embed" | _], query), do: :embeddable, else: :vector
    [attribute_name!(ctx, field, need), op, query]
  end

  defp score_call(ctx, {"SparseKNN", [field, weights]}, _expr) do
    [attribute_name!(ctx, field, :sparse), "SparseKNN", value(weights, ctx)]
  end

  defp score_call(ctx, _call, expr), do: error!(ctx.query, "turbopuffer can't rank by #{Macro.to_string(expr)}")

  defp vector_query(ctx, expr) do
    case call(expr) do
      {"Embed", [text]} -> ["Embed", value(text, ctx)]
      {"Embed", [text, model]} -> ["Embed", value(text, ctx), %{"model" => value(model, ctx)}]
      _ -> value(expr, ctx)
    end
  end

  # ------------------------------------------------------------------------------------------------
  # where
  # ------------------------------------------------------------------------------------------------

  defp filters(%{query: %{wheres: []}}), do: nil

  defp filters(%{query: %{wheres: wheres}} = ctx) do
    wheres
    |> Enum.map(fn %{op: op, expr: expr} -> {op, filter(ctx, expr)} end)
    |> Enum.reduce(nil, fn
      {_op, filter}, nil -> filter
      {:and, filter}, acc -> combine("And", acc, filter)
      {:or, filter}, acc -> combine("Or", acc, filter)
    end)
  end

  # Joins two filters or scores under `op`, flattening either side that already uses it.
  defp combine(op, left, right), do: [op, terms(op, left) ++ terms(op, right)]

  defp terms(op, [op, terms]), do: terms
  defp terms(_op, expr), do: [expr]

  @comparisons %{:== => "Eq", :!= => "NotEq", :< => "Lt", :<= => "Lte", :> => "Gt", :>= => "Gte"}
  @flipped %{:== => :==, :!= => :!=, :< => :>, :<= => :>=, :> => :<, :>= => :<=}

  defp filter(ctx, {:and, _, [left, right]}), do: combine("And", filter(ctx, left), filter(ctx, right))
  defp filter(ctx, {:or, _, [left, right]}), do: combine("Or", filter(ctx, left), filter(ctx, right))

  defp filter(ctx, {:not, _, [{:is_nil, _, [field]}]}), do: [attribute_name!(ctx, field, :filterable), "NotEq", nil]

  defp filter(ctx, {:not, _, [{:in, _, [left, right]}]}) do
    case filter(ctx, {:in, [], [left, right]}) do
      [name, "In", values] -> [name, "NotIn", values]
      [name, "Contains", value] -> [name, "NotContains", value]
    end
  end

  defp filter(ctx, {:not, _, [expr]}), do: ["Not", filter(ctx, expr)]

  defp filter(ctx, {:is_nil, _, [field]}), do: [attribute_name!(ctx, field, :filterable), "Eq", nil]

  defp filter(ctx, {op, _, [left, right]}) when is_map_key(@comparisons, op) do
    cond do
      field?(left) -> [attribute_name!(ctx, left, :filterable), @comparisons[op], value(right, ctx)]
      field?(right) -> [attribute_name!(ctx, right, :filterable), @comparisons[@flipped[op]], value(left, ctx)]
      true -> error!(ctx.query, "turbopuffer filters compare a field to a value")
    end
  end

  defp filter(ctx, {:in, _, [left, right]}) do
    cond do
      field?(left) -> [attribute_name!(ctx, left, :filterable), "In", List.wrap(value(right, ctx))]
      field?(right) -> [attribute_name!(ctx, right, :filterable), "Contains", value(left, ctx)]
      true -> error!(ctx.query, "turbopuffer `in` filters need a field")
    end
  end

  defp filter(ctx, {like, _, [field, pattern]}) when like in [:like, :ilike] do
    op = if like == :like, do: "Glob", else: "IGlob"
    [attribute_name!(ctx, field, "glob"), op, like_to_glob(value(pattern, ctx))]
  end

  defp filter(ctx, expr) do
    case call(expr) do
      {op, [field, value | params]} when is_map_key(@filters, op) and length(params) <= 1 ->
        params = if op == "Fuzzy" and params == [], do: [@fuzzy_params], else: options(params, ctx)
        [attribute_name!(ctx, field, @filters[op]), op, value(value, ctx) | params]

      _ ->
        error!(ctx.query, "turbopuffer can't filter by #{Macro.to_string(expr)}")
    end
  end

  # SQL's % and _ become glob's * and ?, and glob's own metacharacters match literally.
  defp like_to_glob(pattern) when is_binary(pattern) do
    pattern
    |> String.graphemes()
    |> like_to_glob([])
  end

  defp like_to_glob(["\\", char | rest], acc), do: like_to_glob(rest, [escape_glob(char) | acc])
  defp like_to_glob(["%" | rest], acc), do: like_to_glob(rest, ["*" | acc])
  defp like_to_glob(["_" | rest], acc), do: like_to_glob(rest, ["?" | acc])
  defp like_to_glob([char | rest], acc), do: like_to_glob(rest, [escape_glob(char) | acc])
  defp like_to_glob([], acc), do: acc |> Enum.reverse() |> Enum.join()

  defp escape_glob(char) when char in ["*", "?", "[", "]", "{", "}", "\\"], do: "[" <> char <> "]"
  defp escape_glob(char), do: char

  # ------------------------------------------------------------------------------------------------
  # fields and values
  # ------------------------------------------------------------------------------------------------

  defp field?({{:., _, [{:&, _, [_]}, field]}, _, []}) when is_atom(field), do: true
  defp field?(_expr), do: false

  # Schemaless queries have no attributes to check, so they send field names as they are.
  defp attribute_name!(ctx, {{:., _, [{:&, _, [0]}, field]}, _, []}, need) when is_atom(field) do
    name = Atom.to_string(field)
    if ctx.attributes, do: require_index!(ctx, attribute!(ctx, name), need)
    name
  end

  defp attribute_name!(ctx, expr, _need), do: error!(ctx.query, "expected a field, got: #{Macro.to_string(expr)}")

  defp attribute!(ctx, name) do
    Map.get(ctx.attributes, name) || error!(ctx.query, "#{inspect(ctx.schema)} has no field #{inspect(name)}")
  end

  defp require_index!(_ctx, _attribute, :any), do: :ok
  defp require_index!(_ctx, %{primary_key: true}, :filterable), do: :ok
  defp require_index!(_ctx, %{filterable: true}, :filterable), do: :ok
  defp require_index!(_ctx, %{type: {:vector, _, _}}, :vector), do: :ok
  defp require_index!(_ctx, %{type: {:multi_vector, _, _}}, :vector), do: :ok
  defp require_index!(_ctx, %{type: {:vector, _, _}}, :embeddable), do: :ok
  defp require_index!(_ctx, %{schema_entry: %{"embed" => _}}, :embeddable), do: :ok
  defp require_index!(_ctx, %{type: {:sparse_vector, _}}, :sparse), do: :ok
  defp require_index!(_ctx, %{filterable: true}, "glob"), do: :ok

  defp require_index!(ctx, attribute, option) when is_binary(option) do
    unless attribute.schema_entry[option] not in [nil, false] do
      error!(ctx.query, "#{inspect(attribute.field)} needs `#{option}:` in #{inspect(ctx.schema)}")
    end
  end

  defp require_index!(ctx, attribute, :filterable) do
    error!(ctx.query, "#{inspect(attribute.field)} isn't filterable in #{inspect(ctx.schema)}")
  end

  defp require_index!(ctx, attribute, need) do
    error!(ctx.query, "#{inspect(attribute.field)} isn't a #{need} field in #{inspect(ctx.schema)}")
  end

  defp patch_name!(ctx, field) do
    name = Atom.to_string(field)

    if message = ctx.attributes && TP.Attribute.patch_error(attribute!(ctx, name)) do
      error!(ctx.query, message)
    end

    name
  end

  defp literal?(%Tagged{}), do: true
  defp literal?({:^, _, _}), do: true
  defp literal?(value), do: is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value)

  defp value({:^, _, [ix]}, ctx), do: Enum.at(ctx.params, ix)
  defp value({:^, _, [ix, count]}, ctx), do: Enum.slice(ctx.params, ix, count)
  defp value(%Tagged{value: value}, ctx), do: value(value, ctx)
  defp value(list, ctx) when is_list(list), do: Enum.map(list, &value(&1, ctx))

  defp value(literal, _ctx) when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal),
    do: literal

  defp value(expr, ctx), do: error!(ctx.query, "turbopuffer can't use #{Macro.to_string(expr)} as a value")

  # Option arguments, like BM25's `%{last_as_prefix: true}`, as turbopuffer's JSON objects.
  defp options(exprs, ctx) when is_list(exprs), do: Enum.map(exprs, &options(value(&1, ctx)))

  defp options(options) when is_list(options) or is_map(options) do
    Map.new(options, fn {key, value} -> {to_string(key), json(value)} end)
  end

  defp json(values) when is_list(values), do: Enum.map(values, &json/1)
  defp json(%{} = map) when not is_struct(map), do: options(map)
  defp json(value), do: value

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp error!(query, message), do: raise(Ecto.QueryError, query: query, message: message)
end
