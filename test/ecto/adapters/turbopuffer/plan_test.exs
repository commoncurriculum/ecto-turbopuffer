defmodule Ecto.Adapters.Turbopuffer.PlanTest do
  # What the adapter refuses before sending anything, so these run without turbopuffer. What it sends is tested
  # against turbopuffer itself.
  use ExUnit.Case, async: true

  import Ecto.Query
  import TP.Query

  alias Ecto.Adapters.Turbopuffer.Plan
  alias TP.Test.{CardStack, Everything, Lesson}

  defp plan(queryable, opts \\ []) do
    query = queryable |> Ecto.Queryable.to_query() |> Ecto.Query.Planner.ensure_select(true)
    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.Turbopuffer, query)
    Plan.all(query, params, opts)
  end

  defp write(operation, queryable) do
    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(operation, Ecto.Adapters.Turbopuffer, queryable)
    apply(Plan, operation, [query, params])
  end

  defp upserts(schema, on_conflict, opts) do
    meta = %{schema: schema, source: schema && schema.__schema__(:source), prefix: nil}
    Plan.upserts(meta, [[id: "a", title: "T", vector: "AAAA"]], on_conflict, opts)
  end

  defp assert_refused(cases) do
    for {query, message} <- cases do
      assert_raise Ecto.QueryError, message, fn -> plan(query) end
    end
  end

  @vector [1.0, 0.0, 0.0]

  test "filters on attributes without the index they need" do
    assert_refused([
      {from(c in CardStack, where: c.markdown == "x"), ~r/:markdown isn't filterable in TP.Test.CardStack/},
      {from(c in CardStack, where: fuzzy(c.markdown, "x")), ~r/:markdown needs `fuzzy:`/},
      {from(c in CardStack, where: like(c.markdown, "x")), ~r/:markdown needs `glob: true` or to be filterable/},
      {from(c in CardStack, where: contains_all_tokens(c.planbook_id, "x")),
       ~r/:planbook_id needs `full_text_search:`/},
      {from(e in Everything, where: regex(e.tags, "x")), ~r/:tags needs `regex:`/},
      {from(l in Lesson, where: like(l.id, "abc%")), ~r/:id isn't a string or \[\]string, so it can't be matched/}
    ])
  end

  test "filters turbopuffer has no operator for" do
    assert_refused([
      {from(c in CardStack, where: fragment("Glob(?, ?)", c.title, ^"x*")), ~r/turbopuffer can't run string fragments/},
      {from(c in CardStack, where: fragment(Nope: [c.title])), ~r/turbopuffer has no operator :Nope/},
      {from(c in CardStack, where: like(c.title, ^nil)), ~r/like and ilike need a pattern string, got: nil/},
      {from(c in CardStack, where: c.position == c.position), ~r/turbopuffer filters compare a field to a value/},
      {from(c in CardStack, where: fragment(Fuzzy: [c.title, "a", "b", "c"])), ~r/wrong number of arguments/},
      {from(c in CardStack, where: c.title == ref_new(c.title)), ~r/ref_new\/1 is the value being written/}
    ])
  end

  test "orderings turbopuffer can't rank" do
    assert_refused([
      {from(e in Everything, order_by: ^List.duplicate(:position, 9), limit: 5), ~r/orders by at most 8 attributes/},
      {from(c in CardStack, order_by: [asc_nulls_last: c.position], limit: 1),
       ~r/nulls first ascending and last descending/},
      {from(c in CardStack, order_by: bm25(c.markdown, "x"), limit: 1), ~r/highest scores first, so order it desc/},
      {from(c in CardStack, order_by: [desc: ann(c.vector, ^@vector)], limit: 1),
       ~r/closest vectors first, so order it asc/},
      {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x") + ann(c.vector, ^@vector)], limit: 1),
       ~r/can't combine scores that rank in different directions/},
      {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x") * bm25(c.title, "y")], limit: 1),
       ~r/can only multiply a score by a number/},
      {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x"), asc: c.position], limit: 1),
       ~r/can't combine a search with other orderings/},
      {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x") + 1], limit: 1), ~r/can't rank by 1/},
      {from(c in CardStack, order_by: [desc: max_score(1, 2)], limit: 1), ~r/can't take the Max of two numbers/},
      {from(c in CardStack, order_by: [desc: saturate(ann(c.vector, ^@vector), 1)], limit: 1),
       ~r/can't saturate a vector distance/},
      {from(c in CardStack, order_by: vector_distance(c.vector, ^@vector), limit: 1),
       ~r/can't rank by fragment\(VectorDist/},
      {from(c in CardStack, order_by: [desc: c.position == c.position], limit: 1),
       ~r/filters compare a field to a value/},
      {from(c in CardStack, order_by: [desc: c.position == 1 or true], limit: 1),
       ~r/can't score by .*position.* == 1 or true/}
    ])
  end

  test "scores of attributes without what they need" do
    assert_refused([
      {from(c in CardStack, order_by: [desc: bm25(c.planbook_id, "x")], limit: 1),
       ~r/:planbook_id needs `full_text_search:` in TP.Test.CardStack/},
      {from(c in CardStack, order_by: ann(c.markdown, ^[1.0]), limit: 1), ~r/:markdown has no ANN index/},
      {from(c in CardStack, order_by: ann(c.markdown, embed(^"x")), limit: 1), ~r/:markdown isn't embedded text/},
      {from(c in CardStack, order_by: ann(c.markdown, embed(^"x", ^"m")), limit: 1),
       ~r/:markdown isn't embedded text or a vector/},
      {from(c in CardStack, order_by: ann(c.vector, embed(^"x")), limit: 1),
       ~r/:vector is a vector, so embed\(text\) needs the model: embed\(\^text, \^model\)/},
      {from(c in CardStack, order_by: knn(c.title, ^[1.0]), limit: 1), ~r/:title isn't a vector/},
      {from(c in CardStack, order_by: [desc: sparse_knn(c.vector, ^%{})], limit: 1), ~r/:vector isn't a sparse vector/},
      {from(c in CardStack, order_by: ann(c.vector, dist()), limit: 1), ~r/expected a vector or embed\(text\)/},
      {from(c in CardStack, order_by: [desc: attribute(c.title)], limit: 1),
       ~r/:title isn't a filterable int, uint, float, or datetime, so it can't be scored/},
      {from(c in CardStack, order_by: [desc: attribute(c.markdown)], limit: 1), ~r/:markdown isn't a filterable int/},
      {from(e in Everything, order_by: [desc: attribute(e.updated_at)], limit: 1),
       ~r/attribute\/1 scores numbers, so score a datetime with distance\/2/},
      {from(e in Everything, order_by: [desc: decay(distance(e.updated_at, ^"soon"), "1d")], limit: 1),
       ~r/"soon" isn't a datetime/}
    ])
  end

  test "selects turbopuffer can't compute" do
    assert_refused([
      {from(c in CardStack, select: ann(c.vector, ^@vector), limit: 1),
       ~r/can't compute ANN per row; select vector_distance\(field, vector\) instead/},
      {from(c in CardStack, select: vector_distance(c.vector, embed(^"x", ^"m")), limit: 1),
       ~r/turbopuffer only embeds text for ann and knn/},
      {from(c in CardStack, select: highlight(c.planbook_id), limit: 1), ~r/:planbook_id needs `full_text_search:`/},
      {from(c in CardStack, select: embed(^"x"), limit: 1), ~r/turbopuffer can't select fragment\(Embed/}
    ])
  end

  test "limits beyond turbopuffer's 10,000 rows" do
    assert_refused([
      {from(c in CardStack, order_by: c.position), ~r/at most 10000 results per query, so add a limit/},
      {from(c in CardStack, offset: 5), ~r/at most 10000 results per query, so add a limit/},
      {from(c in CardStack, limit: 0), ~r/limits must be between 1 and 10000, got: 0/},
      {from(c in CardStack, limit: 10_001), ~r/limits must be between 1 and 10000, got: 10001/},
      {from(c in CardStack, order_by: c.position, limit: 10_000, offset: 5),
       ~r/limit \+ offset can't exceed it, got: 10000 \+ 5/},
      {from(c in CardStack, order_by: c.position, limit: 10, offset: -1), ~r/offsets must be integers of at least 0/},
      {from(c in CardStack, order_by: c.position, limit: 1) |> with_ties(true), ~r/no limits with ties/}
    ])
  end

  test "limit_per without a limit, or on fields it can't cap" do
    query = from c in CardStack, order_by: [desc: c.position], limit: 10

    for {query, limit_per, exception, message} <- [
          {CardStack, {[:planbook_id], 1}, Ecto.QueryError, ~r/limit_per needs a query with a limit/},
          {from(c in CardStack, select: count()), {[:planbook_id], 1}, Ecto.QueryError,
           ~r/caps rows, not aggregations/},
          {query, {[:nope], 1}, Ecto.QueryError, ~r/has no field :nope for limit_per/},
          {query, {[:markdown], 1}, Ecto.QueryError, ~r/:markdown isn't filterable/},
          {query, {[:planbook_id], 0}, ArgumentError, ~r/:limit_per must be \{fields, limit\}/},
          {query, [planbook_id: 1], ArgumentError, ~r/:limit_per must be \{fields, limit\}/},
          {union_all(query, ^query), {[:planbook_id], 1}, ArgumentError, ~r/limit_per can't cap a union_all's rows/}
        ] do
      assert_raise exception, message, fn -> plan(query, limit_per: limit_per) end
    end
  end

  test "aggregations turbopuffer can't run" do
    assert_refused([
      {from(c in CardStack, select: count(c.title)), ~r/counts documents, so use count\(\) instead/},
      {from(c in CardStack, select: avg(c.position)), ~r/can't aggregate avg/},
      {from(c in CardStack, select: count(), order_by: c.position), ~r/can't order aggregations/},
      {from(c in CardStack, select: count(), offset: 1), ~r/can't offset aggregations/},
      {from(c in CardStack, select: {c.title, count()}), ~r/select only aggregates and group_by fields/},
      {from(c in CardStack, group_by: c.title, select: c.title), ~r/group_by needs an aggregate/},
      {from(c in CardStack, group_by: c.planbook_id, select: {c.planbook_id, count()}),
       ~r/at most 10000 groups, so add a limit/}
    ])
  end

  describe "union_all" do
    setup do
      text = from c in CardStack, order_by: [desc: bm25(c.markdown, ^"x")], limit: 2, select: {c.id, c.title}
      vector = from c in CardStack, order_by: ann(c.vector, ^[0.0, 0.0, 1.0]), limit: 2, select: {c.id, c.markdown}
      {:ok, text: text, vector: vector}
    end

    test "of what a multi-query can't run", %{text: text} do
      lesson = from l in Lesson, order_by: ann(l.markdown, embed(^"x")), limit: 2, select: {l.id, l.markdown}

      assert_refused([
        {union_all(text, ^from(c in CardStack, select: {c.id, c.title})), ~r/each search in a union_all needs a limit/},
        {union_all(text, ^from(c in CardStack, select: count())), ~r/can't combine aggregations/},
        {union(text, ^text), ~r/can only combine searches with union_all, not union/},
        {Enum.reduce(1..16, text, fn _, acc -> union_all(acc, ^text) end), ~r/at most 16 queries in a union_all/},
        {union_all(text, ^lesson), ~r/a union_all runs against one namespace, not card_stacks, lessons/},
        {union_all(text, ^put_query_prefix(text, "other")), ~r/not card_stacks, other-card_stacks/}
      ])
    end

    test "with a rerank_by it can't fuse", %{text: text, vector: vector} do
      same = vector |> exclude(:select) |> select([c], {c.id, c.title})

      for {query, opts, message} <- [
            {union_all(text, ^same), [rerank_by: {:rrf, wieghts: [1, 5]}], ~r/unknown keys \[:wieghts\]/},
            {union_all(text, ^same), [rerank_by: {:rrf, weights: [1]}],
             ~r/a weight above 0 for each of the 2 searches/},
            {union_all(text, ^same), [rerank_by: {:rrf, weights: [0, -1]}], ~r/a weight above 0 for each/},
            {union_all(text, ^same), [rerank_by: {:rrf, weights: ["a", nil]}], ~r/a weight above 0 for each/},
            {union_all(text, ^same), [rerank_by: {:rrf, rank_constant: 0}],
             ~r/rank_constant must be an integer above 0/},
            {union_all(text, ^same), [rerank_by: {:rrf, limit: 10_000, offset: 1}], ~r/rerank_by: .*can't exceed/},
            {union_all(text, ^same), [rerank_by: :mmr], ~r/unknown :rerank_by :mmr/},
            {text, [rerank_by: :rrf], ~r/rerank_by fuses the searches of a union_all, but this query has only one/}
          ] do
        assert_raise ArgumentError, message, fn -> plan(query, opts) end
      end

      assert_raise Ecto.QueryError, ~r/so they must select the same fields/, fn ->
        plan(union_all(text, ^vector), rerank_by: :rrf)
      end
    end
  end

  test "query features turbopuffer doesn't have" do
    assert_refused([
      {from(c in CardStack, join: o in CardStack, on: o.id == c.id), ~r/no joins/},
      {from(c in CardStack, distinct: true), ~r/no distinct/},
      {from(c in CardStack, group_by: c.planbook_id, having: count() > 1, select: count()), ~r/no having/},
      {from(c in subquery(from c in CardStack, limit: 1)), ~r/no subqueries/},
      {from(c in CardStack, lock: "FOR UPDATE"), ~r/no locks/}
    ])

    assert_raise ArgumentError, ~r/:consistency must be :strong or :eventual/, fn ->
      plan(CardStack, consistency: :weak)
    end
  end

  test "update_all and delete_all of what turbopuffer can't patch or filter" do
    for {operation, query, exception, message} <- [
          {:update_all, from(c in CardStack, update: [set: [vector: ^@vector]]), ArgumentError,
           ~r/:vector can't be patched/},
          {:update_all, from(c in CardStack, update: [inc: [position: 1]]), Ecto.QueryError,
           ~r/can only `set` fields in update_all, not inc/},
          {:delete_all, from(c in CardStack, select: c.id), Ecto.QueryError,
           ~r/turbopuffer's delete_all can't return rows/},
          {:delete_all, from(c in CardStack, where: c.markdown == "x"), Ecto.QueryError, ~r/:markdown isn't filterable/}
        ] do
      assert_raise exception, message, fn -> write(operation, query) end
    end
  end

  test "upserts turbopuffer can't run" do
    fields = CardStack.__schema__(:fields) -- [:id]
    newer = dynamic([c], c.position < ref_new(c.position))

    for {schema, on_conflict, opts, message} <- [
          {CardStack, {[:title], [], []}, [],
           ~r/must replace every field, e.g. :replace_all. It leaves out \["markdown"/},
          {CardStack, {%Ecto.Query{}, [], []}, [], ~r/can't run an update on conflict/},
          {nil, {:raise, [], []}, [], ~r/turbopuffer writes need a schema/},
          {CardStack, {:nothing, [], []}, [batch_size: 0], ~r/:batch_size must be an integer above 0, got: 0/},
          {CardStack, {:raise, [], []}, [replace_if: newer], ~r/:replace_if .* needs on_conflict: :replace_all/},
          {CardStack, {fields, [], []}, [replace_if: "newer"], ~r/:replace_if must be a dynamic or a query/},
          {CardStack, {:raise, [], []}, [disable_backpressure: true],
           ~r/can't disable backpressure for conditional writes/},
          {CardStack, {fields, [], []}, [replace_if: newer, disable_backpressure: true],
           ~r/can't disable backpressure/},
          {CardStack, {fields, [], []}, [disable_backpressure: "yes"], ~r/:disable_backpressure must be a boolean/}
        ] do
      assert_raise ArgumentError, message, fn -> upserts(schema, on_conflict, opts) end
    end
  end

  test "recall of a query's own search, which turbopuffer answers with a 404" do
    query = from c in CardStack, order_by: ann(c.vector, ^@vector), limit: 3
    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(:all, Ecto.Adapters.Turbopuffer, query)

    assert_raise Ecto.QueryError, ~r/recall endpoint can't take a rank_by yet/, fn -> Plan.recall(query, params, []) end
  end

  test "namespace names turbopuffer doesn't allow" do
    assert_raise ArgumentError, ~r/must match \[A-Za-z0-9-_.\]\{1,128\}, got: "card stacks-card_stacks"/, fn ->
      plan(put_query_prefix(from(c in CardStack), "card stacks"))
    end
  end
end
