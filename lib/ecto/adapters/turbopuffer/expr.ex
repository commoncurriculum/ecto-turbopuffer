defmodule Ecto.Adapters.Turbopuffer.Expr do
  @moduledoc false
  # Compiles a planned query's expressions into turbopuffer's JSON: filters, rank_by scores, and values
  # (docs/turbopuffer/query.md). `ctx` is Plan's: the query, its params, and its TP.Namespace (nil when schemaless).

  alias Ecto.Query.Tagged

  # A filter no document matches, since ids can't be null.
  @nothing ["id", "Eq", nil]

  # turbopuffer requires max_edit_distance, and each step's min_query_chars must be at least 3 * (distance + 1).
  @fuzzy_options %{
    "max_edit_distance" => [
      %{"min_query_chars" => 3, "distance" => 0},
      %{"min_query_chars" => 6, "distance" => 1},
      %{"min_query_chars" => 9, "distance" => 2}
    ]
  }

  @operators %{:== => "Eq", :!= => "NotEq", :< => "Lt", :<= => "Lte", :> => "Gt", :>= => "Gte"}
  @negated %{:== => :!=, :!= => :==, :< => :>=, :<= => :>, :> => :<=, :>= => :<}
  @flipped %{:== => :==, :!= => :!=, :< => :>, :<= => :>=, :> => :<, :>= => :<=}

  @doc """
  The query's wheres as one filter, or `true` or `false` when they're constant.
  """
  def filters(%{query: %{wheres: wheres}} = ctx) do
    Enum.reduce(wheres, true, fn
      %{op: :and, expr: expr}, acc -> junction(:and, acc, filter(ctx, expr, false))
      %{op: :or, expr: expr}, acc -> junction(:or, acc, filter(ctx, expr, false))
    end)
  end

  @doc "A `filters` result as turbopuffer's filter, with `true` as `every`."
  def filter_json(true, every), do: every
  def filter_json(false, _every), do: @nothing
  def filter_json(filter, _every), do: filter

  @doc "Joins two filters, or `true`/`false`, with And or Or."
  def junction(:and, false, _right), do: false
  def junction(:and, _left, false), do: false
  def junction(:and, true, right), do: right
  def junction(:and, left, true), do: left
  def junction(:or, true, _right), do: true
  def junction(:or, _left, true), do: true
  def junction(:or, false, right), do: right
  def junction(:or, left, false), do: left
  def junction(:and, left, right), do: combine("And", left, right)
  def junction(:or, left, right), do: combine("Or", left, right)

  @doc """
  The query's order_bys as turbopuffer's rank_by, and the direction a cursor pages in when it orders by id alone.
  """
  def rank_by(%{query: %{order_bys: order_bys}} = ctx) do
    case Enum.flat_map(order_bys, & &1.expr) do
      [] ->
        {["id", "asc"], :asc}

      [{direction, expr}] ->
        if field?(expr) do
          {name, direction} = order(ctx, direction, expr)
          {[name, Atom.to_string(direction)], if(name == "id", do: direction)}
        else
          {search(ctx, direction, expr), nil}
        end

      orders when length(orders) > 8 ->
        error!(ctx, "turbopuffer orders by at most 8 attributes")

      orders ->
        ranks =
          Enum.map(orders, fn {direction, expr} ->
            unless field?(expr), do: error!(ctx, "turbopuffer can't combine a search with other orderings")
            {name, direction} = order(ctx, direction, expr)
            [name, Atom.to_string(direction)]
          end)

        {ranks, nil}
    end
  end

  @doc """
  A selected expression: `{:attribute, name}`, `{:literal, value}`, `:dist`, or `{:compute, expr}` for a
  score turbopuffer computes per row.
  """
  def selected(ctx, expr) do
    cond do
      field?(expr) ->
        {:attribute, name!(ctx, expr, nil)}

      literal?(expr) ->
        {:literal, value(ctx, expr)}

      true ->
        # compute_attributes takes BM25 and VectorDist, not the other scores.
        case operator(ctx, expr) do
          {%{role: :dist}, []} ->
            :dist

          {%{op: "BM25"} = op, args} ->
            {:compute, elem(score_call(ctx, op, args), 0)}

          {%{role: :compute} = op, [field, vector]} ->
            {:compute, [name!(ctx, field, op.needs), op.op, vector!(ctx, vector)]}

          _ ->
            error!(ctx, "turbopuffer can't select #{Macro.to_string(expr)}")
        end
    end
  end

  @doc "Whether an expression is a field of the query's source."
  def field?({{:., _, [{:&, _, [_]}, field]}, _, []}) when is_atom(field), do: true
  def field?(_expr), do: false

  @doc """
  The attribute name of a field, after checking the attribute has `capability` (any when nil). Schemaless
  queries have no attributes to check, so their field names go as they are.
  """
  def name!(ctx, {{:., _, [{:&, _, [0]}, field]}, _, []}, capability) when is_atom(field) do
    name = Atom.to_string(field)

    with %TP.Namespace{} = namespace <- ctx.namespace do
      attribute =
        namespace.by_name[name] || error!(ctx, "#{inspect(namespace.module)} has no field #{inspect(name)}")

      if message = capability && TP.Attribute.missing(attribute, capability) do
        error!(ctx, "#{message} in #{inspect(namespace.module)}")
      end
    end

    name
  end

  def name!(ctx, expr, _capability), do: error!(ctx, "expected a field, got: #{Macro.to_string(expr)}")

  @doc "A literal or parameter's value."
  def value(ctx, {:^, _, [ix]}), do: Enum.at(ctx.params, ix)
  def value(ctx, {:^, _, [ix, count]}), do: Enum.slice(ctx.params, ix, count)
  def value(ctx, %Tagged{value: value}), do: value(ctx, value)
  def value(ctx, list) when is_list(list), do: Enum.map(list, &value(ctx, &1))

  def value(_ctx, literal) when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal),
    do: literal

  def value(ctx, expr), do: error!(ctx, "turbopuffer can't use #{Macro.to_string(expr)} as a value")

  def error!(%{query: query}, message), do: raise(Ecto.QueryError, query: query, message: message)

  # ------------------------------------------------------------------------------------------------
  # filters
  # ------------------------------------------------------------------------------------------------

  # `negate` pushes `not` down to the comparisons, so that ordering comparisons never match null (see below).
  defp filter(ctx, {:and, _, [left, right]}, negate) do
    junction(if(negate, do: :or, else: :and), filter(ctx, left, negate), filter(ctx, right, negate))
  end

  defp filter(ctx, {:or, _, [left, right]}, negate) do
    junction(if(negate, do: :and, else: :or), filter(ctx, left, negate), filter(ctx, right, negate))
  end

  defp filter(ctx, {:not, _, [expr]}, negate), do: filter(ctx, expr, not negate)

  defp filter(ctx, {:is_nil, _, [field]}, negate) do
    [name!(ctx, field, :filter), if(negate, do: "NotEq", else: "Eq"), nil]
  end

  defp filter(ctx, {op, _, [left, right]}, negate) when is_map_key(@operators, op) do
    op = if negate, do: @negated[op], else: op

    cond do
      field?(left) -> compare(name!(ctx, left, :filter), op, value(ctx, right))
      field?(right) -> compare(name!(ctx, right, :filter), @flipped[op], value(ctx, left))
      true -> error!(ctx, "turbopuffer filters compare a field to a value")
    end
  end

  defp filter(ctx, {:in, _, [left, right]}, negate) do
    cond do
      field?(left) -> [name!(ctx, left, :filter), if(negate, do: "NotIn", else: "In"), List.wrap(value(ctx, right))]
      field?(right) -> [name!(ctx, right, :filter), if(negate, do: "NotContains", else: "Contains"), value(ctx, left)]
      true -> error!(ctx, "turbopuffer `in` filters need a field")
    end
  end

  defp filter(ctx, {like, _, [field, pattern]}, negate) when like in [:like, :ilike] do
    op = if like == :like, do: "Glob", else: "IGlob"
    [name!(ctx, field, :glob), if(negate, do: "Not" <> op, else: op), glob!(ctx, value(ctx, pattern))]
  end

  # `dynamic(true)`, the usual seed for building filters up, arrives as a literal.
  defp filter(ctx, expr, negate) do
    if literal?(expr) do
      case value(ctx, expr) do
        boolean when is_boolean(boolean) -> boolean != negate
        other -> error!(ctx, "turbopuffer can't filter by #{inspect(other)}")
      end
    else
      filter = operator_filter(ctx, expr)
      if negate, do: ["Not", filter], else: filter
    end
  end

  defp operator_filter(ctx, expr) do
    case operator(ctx, expr) do
      {%{role: :filter, op: "Fuzzy"} = op, [field, text]} ->
        [name!(ctx, field, op.needs), op.op, value(ctx, text), @fuzzy_options]

      {%{role: :filter} = op, [field, value | options]} ->
        [name!(ctx, field, op.needs), op.op, value(ctx, value) | Enum.map(options, &value(ctx, &1))]

      _ ->
        error!(ctx, "turbopuffer can't filter by #{Macro.to_string(expr)}")
    end
  end

  # turbopuffer's Lt and Lte match null, and its Gt and Gte don't. SQL's comparisons never match null, and these
  # follow SQL, so `not (x > 1)` excludes nulls just like `x <= 1`.
  defp compare(name, op, value) when op in [:<, :<=],
    do: ["And", [[name, @operators[op], value], [name, "NotEq", nil]]]

  defp compare(name, op, value), do: [name, @operators[op], value]

  # SQL's % and _ become glob's * and ?, and glob's own metacharacters match literally.
  defp glob!(_ctx, pattern) when is_binary(pattern), do: pattern |> String.graphemes() |> like_to_glob([])
  defp glob!(ctx, pattern), do: error!(ctx, "like and ilike need a pattern string, got: #{inspect(pattern)}")

  defp like_to_glob(["\\", char | rest], acc), do: like_to_glob(rest, [escape_glob(char) | acc])
  defp like_to_glob(["%" | rest], acc), do: like_to_glob(rest, ["*" | acc])
  defp like_to_glob(["_" | rest], acc), do: like_to_glob(rest, ["?" | acc])
  defp like_to_glob([char | rest], acc), do: like_to_glob(rest, [escape_glob(char) | acc])
  defp like_to_glob([], acc), do: acc |> Enum.reverse() |> Enum.join()

  defp escape_glob(char) when char in ["*", "?", "[", "]", "{", "}", "\\"], do: "[" <> char <> "]"
  defp escape_glob(char), do: char

  # ------------------------------------------------------------------------------------------------
  # rank_by
  # ------------------------------------------------------------------------------------------------

  defp order(ctx, direction, field), do: {name!(ctx, field, :filter), direction!(ctx, direction)}

  defp direction!(_ctx, direction) when direction in [:asc, :asc_nulls_first], do: :asc
  defp direction!(_ctx, direction) when direction in [:desc, :desc_nulls_last], do: :desc

  defp direction!(ctx, direction) do
    error!(ctx, "turbopuffer sorts nulls first ascending and last descending, so it can't order #{direction}")
  end

  defp search(ctx, direction, expr) do
    {rank, natural} = score(ctx, expr)

    if direction!(ctx, direction) != natural do
      message =
        if natural == :asc,
          do: "vector search ranks the closest vectors first, so order it asc",
          else: "turbopuffer ranks the highest scores first, so order it desc"

      error!(ctx, message)
    end

    rank
  end

  # A score's rank_by expression and the direction it ranks best first in.
  defp score(ctx, {:+, _, [left, right]}), do: combine_scores(ctx, "Sum", left, right)

  defp score(ctx, {:*, _, [left, right]} = expr) do
    {weight, score} =
      cond do
        literal?(left) -> {left, right}
        literal?(right) -> {right, left}
        true -> error!(ctx, "turbopuffer can only multiply a score by a number, not #{Macro.to_string(expr)}")
      end

    {rank, direction} = score(ctx, score)
    {["Product", value(ctx, weight), rank], direction}
  end

  defp score(ctx, expr) do
    case operator(ctx, expr) do
      {%{role: :max}, [left, right]} -> combine_scores(ctx, "Max", left, right)
      {%{role: {:score, _}} = op, args} -> score_call(ctx, op, args)
      _ -> error!(ctx, "turbopuffer can't rank by #{Macro.to_string(expr)}")
    end
  end

  defp score_call(ctx, %{op: op, role: {:score, direction}} = operator, [field, query | options])
       when op in ["ANN", "kNN"] do
    query = vector!(ctx, query)
    needs = if match?(["Embed" | _], query), do: :embed, else: operator.needs
    {[name!(ctx, field, needs), op, query | Enum.map(options, &value(ctx, &1))], direction}
  end

  defp score_call(ctx, %{role: {:score, direction}} = operator, [field, query | options]) do
    {[name!(ctx, field, operator.needs), operator.op, value(ctx, query) | Enum.map(options, &value(ctx, &1))],
     direction}
  end

  defp combine_scores(ctx, op, left, right) do
    case {score(ctx, left), score(ctx, right)} do
      {{left, direction}, {right, direction}} ->
        {combine(op, left, right), direction}

      _ ->
        error!(ctx, "turbopuffer can't combine scores that rank in different directions")
    end
  end

  # A vector query: a literal vector, or `embed(text)` for turbopuffer to embed.
  defp vector!(ctx, expr) do
    case operator(ctx, expr) do
      {%{role: :embed}, [text]} -> ["Embed", value(ctx, text)]
      {%{role: :embed}, [text, model]} -> ["Embed", value(ctx, text), %{"model" => value(ctx, model)}]
      nil -> value(ctx, expr)
      _ -> error!(ctx, "expected a vector or embed(text), got: #{Macro.to_string(expr)}")
    end
  end

  # ------------------------------------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------------------------------------

  # A TP.Query operator and its arguments, or nil when the expression isn't a keyword fragment.
  defp operator(ctx, {:fragment, _, [[{key, args}]]} = expr) when is_atom(key) and is_list(args) do
    case TP.Query.__operator__(key) do
      %{arities: arities} = op -> if length(args) in arities, do: {op, args}, else: bad_arity!(ctx, expr)
      nil -> error!(ctx, "turbopuffer has no operator #{inspect(key)} in #{Macro.to_string(expr)}")
    end
  end

  defp operator(ctx, {:fragment, _, [{:raw, _} | _]}) do
    error!(ctx, "turbopuffer can't run string fragments; TP.Query's operators are keyword fragments")
  end

  defp operator(_ctx, _expr), do: nil

  defp bad_arity!(ctx, expr), do: error!(ctx, "wrong number of arguments in #{Macro.to_string(expr)}")

  # Joins two filters or scores under `op`, flattening either side that already uses it.
  defp combine(op, left, right), do: [op, terms(op, left) ++ terms(op, right)]

  defp terms(op, [op, terms]), do: terms
  defp terms(_op, expr), do: [expr]

  defp literal?(%Tagged{}), do: true
  defp literal?({:^, _, _}), do: true
  defp literal?(value), do: is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value)
end
