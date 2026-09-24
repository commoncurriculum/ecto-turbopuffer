defmodule Ecto.Adapters.Turbopuffer.Query do
  @moduledoc false
  # Translates planned Ecto queries into turbopuffer request bodies (docs/turbopuffer/query.md, write.md).

  alias Ecto.Query.Tagged

  @max_limit 10_000
  @every_document ["id", "NotEq", nil]

  defstruct [:namespace, :schema, :body, :readers, :mode, :order]

  @doc """
  Plans a `Repo.all` query. `mode` is `:rows`, `:paginate` (no limit, ordered by id, fetched page by page),
  `:aggregate`, or `:multi` for `union_all`, whose `body` holds the subqueries.
  """
  def all(query, params, opts) do
    plan = plan(query, params)

    case query.combinations do
      [] ->
        plan

      combinations ->
        subplans =
          Enum.map(combinations, fn
            {:union_all, subquery} -> plan(subquery, params)
            {kind, _} -> error!(query, "turbopuffer can only combine searches with union_all, not #{kind}")
          end)

        multi(query, [plan | subplans], opts)
    end
  end

  def delete_all(query, params) do
    check!(query, :delete_all)
    ctx = context(query, params)

    %__MODULE__{
      namespace: ctx.namespace,
      schema: ctx.schema,
      body: %{"delete_by_filter" => filters(ctx) || @every_document}
    }
  end

  def update_all(query, params) do
    check!(query, :update_all)
    ctx = context(query, params)

    patch =
      query.updates
      |> Enum.flat_map(& &1.expr)
      |> Enum.flat_map(fn
        {:set, sets} ->
          Enum.map(sets, fn {field, value} -> {patchable!(ctx, field), value(value, ctx)} end)

        {op, _} ->
          error!(query, "turbopuffer can only `set` fields in update_all, not #{op}")
      end)
      |> Map.new()

    body = %{"patch_by_filter" => %{"filters" => filters(ctx) || @every_document, "patch" => patch}}
    %__MODULE__{namespace: ctx.namespace, schema: ctx.schema, body: body}
  end

  @doc "The row the select asks for, from a turbopuffer row or aggregation."
  def read(%__MODULE__{readers: readers}, row), do: Enum.map(readers, &read_value(&1, row))

  defp read_value({:key, key}, row), do: Map.get(row, key)
  defp read_value({:literal, value}, _row), do: value

  @doc "The body for the page after `rows` when paginating."
  def next_page(%__MODULE__{body: body, order: direction}, rows) do
    last = List.last(rows)["id"]
    after_last = ["id", if(direction == "asc", do: "Gt", else: "Lt"), last]

    filters =
      case body["filters"] do
        nil -> after_last
        filters -> ["And", [filters, after_last]]
      end

    Map.put(body, "filters", filters)
  end

  def max_limit, do: @max_limit

  defp plan(query, params) do
    check!(query, :all)
    ctx = context(query, params)
    fields = query.select.fields

    if Enum.any?(fields, &aggregate?/1) do
      plan_aggregate(query, ctx, fields)
    else
      plan_rows(query, ctx, fields)
    end
  end

  defp plan_rows(query, ctx, fields) do
    {readers, include, compute} = select(ctx, fields)
    {rank_by, direction} = rank_by(ctx)
    limit = limit(ctx)
    offset = if query.offset, do: value(query.offset.expr, ctx)

    mode =
      cond do
        limit != nil -> :rows
        match?(["id", _], rank_by) and offset == nil -> :paginate
        true -> error!(query, "turbopuffer returns at most #{@max_limit} results per query, so add a limit")
      end

    body =
      %{"rank_by" => rank_by, "limit" => limit || @max_limit}
      |> put("filters", filters(ctx))
      |> put("offset", offset)
      |> put("include_attributes", if(include != [], do: include))
      |> put("compute_attributes", if(compute != %{}, do: compute))

    %__MODULE__{
      namespace: ctx.namespace,
      schema: ctx.schema,
      body: body,
      readers: readers,
      mode: mode,
      order: direction
    }
  end

  defp plan_aggregate(query, ctx, fields) do
    if query.order_bys != [], do: error!(query, "turbopuffer can't order aggregations")
    if query.offset, do: error!(query, "turbopuffer can't offset aggregations")

    group_by =
      for %{expr: exprs} <- query.group_bys, expr <- exprs do
        attribute_name!(ctx, expr, :filterable)
      end

    {readers, aggregates} =
      fields
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

    %__MODULE__{namespace: ctx.namespace, schema: ctx.schema, body: body, readers: readers, mode: :aggregate}
  end

  defp multi(query, plans, opts) do
    queries =
      Enum.map(plans, fn
        %{mode: :paginate} -> error!(query, "each search in a union_all needs a limit")
        %{mode: :aggregate} -> error!(query, "turbopuffer can't combine aggregations with union_all")
        plan -> plan.body
      end)

    if length(queries) > 16, do: error!(query, "turbopuffer runs at most 16 queries in a union_all")

    body =
      case Keyword.get(opts, :rerank_by) do
        nil ->
          %{"queries" => queries}

        :rrf ->
          %{"queries" => queries, "rerank_by" => ["RRF"]}

        {:rrf, rrf} ->
          params = rrf |> Keyword.take([:rank_constant, :weights]) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

          %{"queries" => queries, "rerank_by" => if(params == %{}, do: ["RRF"], else: ["RRF", params])}
          |> put("limit", rrf[:limit])
          |> put("offset", rrf[:offset])

        other ->
          raise ArgumentError, "unknown :rerank_by #{inspect(other)}, expected :rrf or {:rrf, opts}"
      end

    %{hd(plans) | body: body, mode: {:multi, Keyword.get(opts, :rerank_by) != nil}}
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

  defp context(query, params) do
    {source, schema, prefix} = elem(query.sources, 0)

    # The planner has already replaced field names with their sources.
    attributes =
      if schema, do: Map.new(TP.__attributes__(schema), &{String.to_existing_atom(&1.name), &1})

    %{
      query: query,
      params: params,
      schema: schema,
      attributes: attributes,
      namespace: namespace(source, prefix)
    }
  end

  @doc "The turbopuffer namespace for an Ecto source and prefix."
  def namespace(source, nil), do: source
  def namespace(source, prefix), do: "#{prefix}-#{source}"

  defp limit(%{query: %{limit: nil}}), do: nil

  defp limit(%{query: %{limit: %{with_ties: true}} = query}),
    do: error!(query, "turbopuffer has no limits with ties")

  defp limit(%{query: %{limit: %{expr: expr}}} = ctx) do
    case value(expr, ctx) do
      limit when is_integer(limit) and limit in 1..@max_limit -> limit
      limit -> error!(ctx.query, "turbopuffer limits must be between 1 and #{@max_limit}, got: #{inspect(limit)}")
    end
  end

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

  defp selected(ctx, field) do
    cond do
      field?(field) -> {:attribute, attribute_name!(ctx, field, :any)}
      match?({:fragment, _, [raw: "$dist"]}, field) -> :dist
      match?({:fragment, _, [{:raw, "BM25("} | _]}, field) -> {:compute, score(ctx, field)}
      match?({:fragment, _, [{:raw, "VectorDist("} | _]}, field) -> {:compute, vector_distance(ctx, field)}
      literal?(field) -> {:literal, value(field, ctx)}
      true -> error!(ctx.query, "turbopuffer can't select #{Macro.to_string(field)}")
    end
  end

  defp vector_distance(ctx, {:fragment, _, [raw: "VectorDist(", expr: field, raw: ", ", expr: vector, raw: ")"]}) do
    [attribute_name!(ctx, field, :vector), "VectorDist", value(vector, ctx)]
  end

  defp literal?(%Tagged{}), do: true
  defp literal?({:^, _, _}), do: true
  defp literal?(value), do: is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value)

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
        {["id", "asc"], "asc"}

      [{direction, expr}] ->
        if field?(expr) do
          name = attribute_name!(ctx, expr, :filterable)
          {[name, direction!(ctx, direction)], direction!(ctx, direction)}
        else
          rank = score(ctx, expr)
          check_score_direction!(ctx, rank, direction)
          {rank, nil}
        end

      orders ->
        if length(orders) > 8, do: error!(ctx.query, "turbopuffer orders by at most 8 attributes")

        ranks =
          Enum.map(orders, fn {direction, expr} ->
            unless field?(expr), do: error!(ctx.query, "turbopuffer can't combine a search with other orderings")
            [attribute_name!(ctx, expr, :filterable), direction!(ctx, direction)]
          end)

        {ranks, nil}
    end
  end

  defp direction!(_ctx, direction) when direction in [:asc, :asc_nulls_first], do: "asc"
  defp direction!(_ctx, direction) when direction in [:desc, :desc_nulls_last], do: "desc"

  defp direction!(ctx, direction) do
    error!(ctx.query, "turbopuffer sorts nulls first ascending and last descending, so it can't order #{direction}")
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

  defp score(ctx, {:+, _, [left, right]}), do: ["Sum", sum_terms(ctx, left) ++ sum_terms(ctx, right)]

  defp score(ctx, {:*, _, [left, right]}) do
    cond do
      literal?(left) -> ["Product", value(left, ctx), score(ctx, right)]
      literal?(right) -> ["Product", value(right, ctx), score(ctx, left)]
      true -> error!(ctx.query, "turbopuffer can only multiply a score by a number")
    end
  end

  defp score(ctx, {:fragment, _, [raw: "Max(", expr: left, raw: ", ", expr: right, raw: ")"]}) do
    ["Max", max_terms(ctx, left) ++ max_terms(ctx, right)]
  end

  defp score(ctx, {:fragment, _, [raw: "BM25(", expr: field, raw: ", ", expr: text, raw: ")"]}) do
    [attribute_name!(ctx, field, "full_text_search"), "BM25", value(text, ctx)]
  end

  defp score(ctx, {:fragment, _, [raw: "BM25(", expr: field, raw: ", ", expr: text, raw: ", ", expr: params, raw: ")"]}) do
    [attribute_name!(ctx, field, "full_text_search"), "BM25", value(text, ctx), params(value(params, ctx))]
  end

  defp score(ctx, {:fragment, _, [raw: open, expr: field, raw: ", ", expr: vector, raw: ")"]})
       when open in ["ANN(", "kNN("] do
    op = String.trim_trailing(open, "(")
    query = vector_query(ctx, vector)
    need = if match?(["Embed" | _], query), do: :embeddable, else: :vector
    [attribute_name!(ctx, field, need), op, query]
  end

  defp score(ctx, {:fragment, _, [raw: "SparseKNN(", expr: field, raw: ", ", expr: weights, raw: ")"]}) do
    [attribute_name!(ctx, field, :sparse), "SparseKNN", value(weights, ctx)]
  end

  defp score(ctx, expr), do: error!(ctx.query, "turbopuffer can't rank by #{Macro.to_string(expr)}")

  defp sum_terms(ctx, expr) do
    case score(ctx, expr) do
      ["Sum", terms] -> terms
      term -> [term]
    end
  end

  defp max_terms(ctx, expr) do
    case score(ctx, expr) do
      ["Max", terms] -> terms
      term -> [term]
    end
  end

  defp vector_query(ctx, {:fragment, _, [raw: "Embed(", expr: text, raw: ")"]}), do: ["Embed", value(text, ctx)]

  defp vector_query(ctx, {:fragment, _, [raw: "Embed(", expr: text, raw: ", ", expr: model, raw: ")"]}) do
    ["Embed", value(text, ctx), %{"model" => value(model, ctx)}]
  end

  defp vector_query(ctx, vector), do: value(vector, ctx)

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

  defp combine(op, left, right), do: [op, terms(op, left) ++ terms(op, right)]

  defp terms(op, [op, terms]), do: terms
  defp terms(_op, filter), do: [filter]

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

  defp filter(ctx, {:fragment, _, [raw: op_open, expr: field, raw: ", ", expr: value, raw: ")"]} = expr) do
    op = operator!(ctx, op_open, expr)
    [attribute_name!(ctx, field, index_for(op)), op, value(value, ctx)] ++ default_params(op)
  end

  defp filter(
         ctx,
         {:fragment, _, [raw: op_open, expr: field, raw: ", ", expr: value, raw: ", ", expr: params, raw: ")"]} = expr
       ) do
    op = operator!(ctx, op_open, expr)
    [attribute_name!(ctx, field, index_for(op)), op, value(value, ctx), params(value(params, ctx))]
  end

  defp filter(ctx, expr), do: error!(ctx.query, "turbopuffer can't filter by #{Macro.to_string(expr)}")

  defp operator!(ctx, op_open, expr) do
    op = String.trim_trailing(op_open, "(")
    if Map.has_key?(TP.Query.filters(), op), do: op, else: error!(ctx.query, "unknown filter #{Macro.to_string(expr)}")
  end

  # turbopuffer requires max_edit_distance, and each step's min_query_chars must be at least 3 * (distance + 1).
  defp default_params("Fuzzy") do
    [
      %{
        "max_edit_distance" => [
          %{"min_query_chars" => 3, "distance" => 0},
          %{"min_query_chars" => 6, "distance" => 1},
          %{"min_query_chars" => 9, "distance" => 2}
        ]
      }
    ]
  end

  defp default_params(_op), do: []

  defp index_for("Fuzzy"), do: "fuzzy"
  defp index_for("Regex"), do: "regex"
  defp index_for(op) when op in ["Glob", "IGlob"], do: "glob"

  defp index_for(op) when op in ["ContainsAllTokens", "ContainsAnyToken", "ContainsTokenSequence"],
    do: "full_text_search"

  defp index_for(_op), do: :filterable

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

  defp attribute_name!(ctx, {{:., _, [{:&, _, [ix]}, field]}, _, []}, need) do
    if ix != 0, do: error!(ctx.query, "turbopuffer has no joins")

    case ctx.attributes do
      nil ->
        Atom.to_string(field)

      attributes ->
        attribute =
          Map.get(attributes, field) || error!(ctx.query, "#{inspect(ctx.schema)} has no field #{inspect(field)}")

        require_index!(ctx, attribute, need)
        attribute.name
    end
  end

  defp attribute_name!(ctx, expr, _need), do: error!(ctx.query, "expected a field, got: #{Macro.to_string(expr)}")

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

  defp patchable!(ctx, field) do
    attribute = ctx.attributes && Map.fetch!(ctx.attributes, field)

    cond do
      attribute == nil ->
        Atom.to_string(field)

      attribute.primary_key ->
        error!(ctx.query, "turbopuffer ids can't change")

      not TP.__patchable__?(attribute) ->
        error!(ctx.query, "turbopuffer can't patch vectors or the text it embeds, so upsert the whole document")

      true ->
        attribute.name
    end
  end

  defp value({:^, _, [ix]}, ctx), do: Enum.at(ctx.params, ix)
  defp value({:^, _, [ix, count]}, ctx), do: Enum.slice(ctx.params, ix, count)
  defp value(%Tagged{value: value}, ctx), do: value(value, ctx)
  defp value(list, ctx) when is_list(list), do: Enum.map(list, &value(&1, ctx))
  defp value({:fragment, _, [{:raw, "Embed("} | _]} = expr, ctx), do: vector_query(ctx, expr)

  defp value(literal, _ctx) when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal),
    do: literal

  defp value(expr, ctx), do: error!(ctx.query, "turbopuffer can't use #{Macro.to_string(expr)} as a value")

  defp params(params) when is_list(params) or is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), json(value)} end)
  end

  defp json(values) when is_list(values), do: Enum.map(values, &json/1)
  defp json(%{} = map) when not is_struct(map), do: params(map)
  defp json(value), do: value

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp error!(query, message), do: raise(Ecto.QueryError, query: query, message: message)
end
