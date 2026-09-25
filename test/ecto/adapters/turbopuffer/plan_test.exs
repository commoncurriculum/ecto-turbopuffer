defmodule Ecto.Adapters.Turbopuffer.PlanTest do
  # The request bodies planned queries and writes compile to, and how responses read back, without turbopuffer.
  use ExUnit.Case, async: true

  import Ecto.Query
  import TP.Query

  alias Ecto.Adapters.Turbopuffer.Plan
  alias TP.Test.{CardStack, Everything, Lesson}

  defp not_nil(name), do: [name, "NotEq", nil]

  defp planned(operation, queryable) do
    query = Ecto.Queryable.to_query(queryable)
    query = if operation == :all, do: Ecto.Query.Planner.ensure_select(query, true), else: query
    {query, _cast, params} = Ecto.Adapter.Queryable.plan_query(operation, Ecto.Adapters.Turbopuffer, query)
    {query, params}
  end

  defp plan(queryable, opts \\ []) do
    {query, params} = planned(:all, queryable)
    Plan.all(query, params, opts)
  end

  defp body(queryable, opts \\ []), do: plan(queryable, opts).body
  defp filters(queryable), do: body(queryable)["filters"]

  describe "filters" do
    test "compare a field to a value, either way round" do
      assert filters(from c in CardStack, where: c.planbook_id == "science") == ["planbook_id", "Eq", "science"]
      assert filters(from c in CardStack, where: c.planbook_id != ^"science") == ["planbook_id", "NotEq", "science"]
      assert filters(from c in CardStack, where: c.position > 2) == ["position", "Gt", 2]
      assert filters(from c in CardStack, where: 2 < c.position) == ["position", "Gt", 2]
      assert filters(from c in CardStack, where: c.position >= 2) == ["position", "Gte", 2]
    end

    test "< and <= exclude nulls, which turbopuffer's Lt and Lte match" do
      assert filters(from c in CardStack, where: c.position < 3) ==
               ["And", [["position", "Lt", 3], not_nil("position")]]

      assert filters(from c in CardStack, where: 2 >= c.position) ==
               ["And", [["position", "Lte", 2], not_nil("position")]]
    end

    test "not flips comparisons, so ordering comparisons still exclude nulls" do
      assert filters(from c in CardStack, where: not (c.position < 3)) == ["position", "Gte", 3]
      assert filters(from c in CardStack, where: not (c.position <= 3)) == ["position", "Gt", 3]

      assert filters(from c in CardStack, where: not (c.position > 3)) ==
               ["And", [["position", "Lte", 3], not_nil("position")]]

      assert filters(from c in CardStack, where: not (c.planbook_id == "x")) == ["planbook_id", "NotEq", "x"]
      assert filters(from c in CardStack, where: not not (c.planbook_id == "x")) == ["planbook_id", "Eq", "x"]
    end

    test "not distributes over and and or" do
      assert filters(from c in CardStack, where: not (c.planbook_id == "x" and c.position > 1)) ==
               ["Or", [["planbook_id", "NotEq", "x"], ["And", [["position", "Lte", 1], not_nil("position")]]]]

      assert filters(from c in CardStack, where: not (c.planbook_id == "x" or is_nil(c.position))) ==
               ["And", [["planbook_id", "NotEq", "x"], not_nil("position")]]
    end

    test "and, or, or_where, in, and nil checks" do
      query = from c in CardStack, where: c.planbook_id == "history" or (c.position == 1 and not (c.title == "Cells"))

      assert filters(query) ==
               ["Or", [["planbook_id", "Eq", "history"], ["And", [["position", "Eq", 1], ["title", "NotEq", "Cells"]]]]]

      assert filters(from c in CardStack, where: c.planbook_id == "a", or_where: c.id == "b") ==
               ["Or", [["planbook_id", "Eq", "a"], ["id", "Eq", "b"]]]

      assert filters(from c in CardStack, where: c.id in ^["a", "b"]) == ["id", "In", ["a", "b"]]
      assert filters(from c in CardStack, where: c.id not in ["a", "b"]) == ["id", "NotIn", ["a", "b"]]
      # Ecto only allows `value in field` on its own array types, so only schemaless queries can use it.
      assert filters(from c in "card_stacks", where: "LS1.C" in c.standard_ids, select: c.id) ==
               ["standard_ids", "Contains", "LS1.C"]

      assert filters(from c in "card_stacks", where: "LS1.C" not in c.standard_ids, select: c.id) ==
               ["standard_ids", "NotContains", "LS1.C"]

      assert filters(from c in CardStack, where: is_nil(c.planbook_id)) == ["planbook_id", "Eq", nil]
      assert filters(from c in CardStack, where: not is_nil(c.planbook_id)) == ["planbook_id", "NotEq", nil]
    end

    test "true and false fold away, so dynamic(true) can seed a filter" do
      seeded = dynamic([c], ^dynamic(true) and c.planbook_id == ^"science")
      assert filters(from c in CardStack, where: ^seeded) == ["planbook_id", "Eq", "science"]
      assert filters(from c in CardStack, where: ^dynamic(true)) == nil
      assert filters(from c in CardStack, where: c.planbook_id == "a" or true) == nil
      assert filters(from c in CardStack, where: c.planbook_id == "a", where: ^true) == ["planbook_id", "Eq", "a"]
      assert filters(from c in CardStack, where: c.planbook_id == "a" and false) == ["id", "Eq", nil]
      assert filters(from c in CardStack, where: not true) == ["id", "Eq", nil]
      assert filters(from c in CardStack, where: false, or_where: c.id == "a") == ["id", "Eq", "a"]
    end

    test "like and ilike become globs" do
      assert filters(from c in CardStack, where: like(c.title, "Photo%")) == ["title", "Glob", "Photo*"]
      assert filters(from c in CardStack, where: ilike(c.title, ^"%REV_")) == ["title", "IGlob", "*REV?"]
      assert filters(from c in CardStack, where: not like(c.title, "a%")) == ["title", "NotGlob", "a*"]
      assert filters(from c in CardStack, where: like(c.title, "100\\%*[x]")) == ["title", "Glob", "100%[*][[]x[]]"]

      assert_raise Ecto.QueryError, ~r/like and ilike need a pattern string, got: nil/, fn ->
        plan(from c in CardStack, where: like(c.title, ^nil))
      end
    end

    test "TP.Query operators" do
      assert [_, "Fuzzy", "fotosynthesis", %{"max_edit_distance" => [_, _, _]}] =
               filters(from c in CardStack, where: fuzzy(c.title, ^"fotosynthesis"))

      strict = %{max_edit_distance: [%{min_query_chars: 3, distance: 0}]}
      assert filters(from c in CardStack, where: fuzzy(c.title, ^"x", ^strict)) == ["title", "Fuzzy", "x", strict]

      assert filters(from c in CardStack, where: contains_all_tokens(c.markdown, ^"mito", ^%{last_as_prefix: true})) ==
               ["markdown", "ContainsAllTokens", "mito", %{last_as_prefix: true}]

      assert filters(from c in CardStack, where: contains_token_sequence(c.markdown, "one cell")) ==
               ["markdown", "ContainsTokenSequence", "one cell"]

      assert filters(from c in CardStack, where: contains_any(c.standard_ids, ^["a", "b"])) ==
               ["standard_ids", "ContainsAny", ["a", "b"]]

      assert filters(from e in Everything, where: any_lt(e.positions, 3)) == ["positions", "AnyLt", 3]
      assert filters(from e in Everything, where: regex(e.title, "^Photo")) == ["title", "Regex", "^Photo"]
      assert filters(from e in Everything, where: iglob(e.tags, "bio*")) == ["tags", "IGlob", "bio*"]

      assert filters(from c in CardStack, where: not contains(c.standard_ids, "LS1.C")) ==
               ["Not", ["standard_ids", "Contains", "LS1.C"]]
    end

    test "string fragments aren't turbopuffer operators" do
      assert_raise Ecto.QueryError, ~r/turbopuffer can't run string fragments/, fn ->
        plan(from c in CardStack, where: fragment("Glob(?, ?)", c.title, ^"x*"))
      end

      assert_raise Ecto.QueryError, ~r/turbopuffer has no operator :Nope/, fn ->
        plan(from c in CardStack, where: fragment(Nope: [c.title]))
      end
    end

    test "check the schema's indexes" do
      for {query, message} <- [
            {from(c in CardStack, where: c.markdown == "x"), ~r/:markdown isn't filterable in TP.Test.CardStack/},
            {from(c in CardStack, where: fuzzy(c.markdown, "x")), ~r/:markdown needs `fuzzy:`/},
            {from(c in CardStack, where: like(c.markdown, "x")), ~r/:markdown needs `glob: true` or to be filterable/},
            {from(c in CardStack, where: contains_all_tokens(c.planbook_id, "x")),
             ~r/:planbook_id needs `full_text_search:`/},
            {from(e in Everything, where: regex(e.tags, "x")), ~r/:tags needs `regex:`/}
          ] do
        assert_raise Ecto.QueryError, message, fn -> plan(query) end
      end
    end

    test "schemaless queries send field names as they are" do
      assert filters(from c in "card_stacks", where: c.anything == "x", select: c.id) == ["anything", "Eq", "x"]
    end

    test "compare against values too big to write, like an id Repo.get is given" do
      long = String.duplicate("a", 65)
      assert filters(from c in CardStack, where: c.id == ^long) == ["id", "Eq", long]
      assert filters(from c in CardStack, where: c.id in ^[long, "a"]) == ["id", "In", [long, "a"]]
    end
  end

  describe "rank_by" do
    test "orders by id by default, or by up to 8 fields" do
      assert body(CardStack)["rank_by"] == ["id", "asc"]
      assert body(from c in CardStack, order_by: [desc: c.position], limit: 5)["rank_by"] == ["position", "desc"]

      assert body(from c in CardStack, order_by: [c.planbook_id, desc: c.position], limit: 5)["rank_by"] ==
               [["planbook_id", "asc"], ["position", "desc"]]

      assert_raise Ecto.QueryError, ~r/orders by at most 8 attributes/, fn ->
        plan(from e in Everything, order_by: ^List.duplicate(:position, 9), limit: 5)
      end

      assert_raise Ecto.QueryError, ~r/nulls first ascending and last descending/, fn ->
        plan(from c in CardStack, order_by: [asc_nulls_last: c.position], limit: 1)
      end
    end

    test "searches with bm25, sums, weights, and max_score" do
      assert body(from c in CardStack, order_by: [desc: bm25(c.markdown, ^"x")], limit: 5)["rank_by"] ==
               ["markdown", "BM25", "x"]

      assert body(from c in CardStack, order_by: [desc: bm25(c.markdown, "x", ^%{last_as_prefix: true})], limit: 5)[
               "rank_by"
             ] == ["markdown", "BM25", "x", %{last_as_prefix: true}]

      query =
        from c in CardStack,
          order_by: [desc: bm25(c.markdown, ^"x") + 3.0 * bm25(c.title, ^"y") + bm25(c.title, "z")],
          limit: 2

      assert body(query)["rank_by"] ==
               ["Sum", [["markdown", "BM25", "x"], ["Product", 3.0, ["title", "BM25", "y"]], ["title", "BM25", "z"]]]

      query = from c in CardStack, order_by: [desc: max_score(bm25(c.title, "a"), bm25(c.markdown, "b"))], limit: 2
      assert body(query)["rank_by"] == ["Max", [["title", "BM25", "a"], ["markdown", "BM25", "b"]]]
    end

    test "vector searches, literal or embedded" do
      assert body(from c in CardStack, order_by: ann(c.vector, ^[1.0, 0.0, 0.0]), limit: 2)["rank_by"] ==
               ["vector", "ANN", [1.0, 0.0, 0.0]]

      assert body(from c in CardStack, order_by: knn(c.vector, ^[1.0, 0.0, 0.0]), limit: 2)["rank_by"] ==
               ["vector", "kNN", [1.0, 0.0, 0.0]]

      assert body(from l in Lesson, order_by: ann(l.markdown, embed(^"leaves")), limit: 2)["rank_by"] ==
               ["markdown", "ANN", ["Embed", "leaves"]]

      assert body(from c in CardStack, order_by: ann(c.vector, embed(^"leaves", ^"m")), limit: 2)["rank_by"] ==
               ["vector", "ANN", ["Embed", "leaves", %{"model" => "m"}]]

      assert body(from e in Everything, order_by: [desc: sparse_knn(e.sparse, ^%{"1" => 1.0})], limit: 2)["rank_by"] ==
               ["sparse", "SparseKNN", %{"1" => 1.0}]
    end

    test "checks each search's direction and attribute" do
      for {query, message} <- [
            {from(c in CardStack, order_by: bm25(c.markdown, "x"), limit: 1),
             ~r/highest scores first, so order it desc/},
            {from(c in CardStack, order_by: [desc: ann(c.vector, ^[1.0, 0.0, 0.0])], limit: 1),
             ~r/closest vectors first, so order it asc/},
            {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x") + ann(c.vector, ^[1.0, 0.0, 0.0])], limit: 1),
             ~r/can't combine scores that rank in different directions/},
            {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x") * bm25(c.title, "y")], limit: 1),
             ~r/can only multiply a score by a number/},
            {from(c in CardStack, order_by: [desc: bm25(c.markdown, "x"), asc: c.position], limit: 1),
             ~r/can't combine a search with other orderings/},
            {from(c in CardStack, order_by: [desc: bm25(c.planbook_id, "x")], limit: 1),
             ~r/:planbook_id needs `full_text_search:` in TP.Test.CardStack/},
            {from(c in CardStack, order_by: ann(c.markdown, ^[1.0]), limit: 1), ~r/:markdown has no ANN index/},
            {from(c in CardStack, order_by: ann(c.markdown, embed(^"x")), limit: 1),
             ~r/:markdown isn't embedded text or a vector/},
            {from(c in CardStack, order_by: knn(c.title, ^[1.0]), limit: 1), ~r/:title isn't a vector/},
            {from(c in CardStack, order_by: [desc: sparse_knn(c.vector, ^%{})], limit: 1),
             ~r/:vector isn't a sparse vector/},
            {from(c in CardStack, order_by: ann(c.vector, dist()), limit: 1), ~r/expected a vector or embed\(text\)/}
          ] do
        assert_raise Ecto.QueryError, message, fn -> plan(query) end
      end
    end
  end

  describe "select" do
    test "includes the selected attributes and reads them back in order" do
      plan = plan(from c in CardStack, where: c.id == "a", select: {c.id, c.title, dist(), c.title})
      assert plan.body["include_attributes"] == ["title"]

      assert Plan.page(plan, %{"rows" => [%{"id" => "a", "title" => "T", "$dist" => 0.5}]}) ==
               {[["a", "T", 0.5, "T"]], nil}
    end

    test "computes bm25 and vector distances per row" do
      body =
        body(
          from c in CardStack,
            select: {c.id, bm25(c.markdown, ^"mitosis"), vector_distance(c.vector, ^[0.0, 1.0, 0.0])},
            limit: 1
        )

      assert body["compute_attributes"] == %{
               "ecto_1" => ["markdown", "BM25", "mitosis"],
               "ecto_2" => ["vector", "VectorDist", [0.0, 1.0, 0.0]]
             }

      assert_raise Ecto.QueryError, ~r/can't select fragment\(ANN:/, fn ->
        plan(from c in CardStack, select: ann(c.vector, ^[1.0, 0.0, 0.0]), limit: 1)
      end
    end
  end

  describe "limits and paging" do
    test "a query ordered by id without a limit reads every page" do
      plan = plan(from c in CardStack, where: c.position > 1, order_by: [desc: c.id])
      assert plan.cursor == :desc
      assert plan.body["limit"] == 10_000

      rows = for i <- 10_000..1//-1, do: %{"id" => "p#{i}"}
      {_rows, next} = Plan.page(plan, %{"rows" => rows})
      assert next["filters"] == ["And", [["position", "Gt", 1], ["id", "Lt", "p1"]]]
      assert Plan.page(%{plan | body: next}, %{"rows" => Enum.take(rows, 3)}) |> elem(1) == nil

      assert Plan.page(plan(CardStack), %{"rows" => rows}) |> elem(1) |> Map.fetch!("filters") ==
               ["id", "Gt", "p1"]
    end

    test "other queries need a limit, and limit + offset can't exceed 10,000" do
      for {query, message} <- [
            {from(c in CardStack, order_by: c.position), ~r/at most 10000 results per query, so add a limit/},
            {from(c in CardStack, offset: 5), ~r/at most 10000 results per query, so add a limit/},
            {from(c in CardStack, limit: 0), ~r/limits must be between 1 and 10000, got: 0/},
            {from(c in CardStack, limit: 10_001), ~r/limits must be between 1 and 10000, got: 10001/},
            {from(c in CardStack, order_by: c.position, limit: 10_000, offset: 5),
             ~r/limit \+ offset can't exceed it, got: 10000 \+ 5/},
            {from(c in CardStack, order_by: c.position, limit: 10, offset: -1),
             ~r/offsets must be integers of at least 0/}
          ] do
        assert_raise Ecto.QueryError, message, fn -> plan(query) end
      end

      assert body(from c in CardStack, order_by: c.position, limit: 9_995, offset: 5)["offset"] == 5
    end
  end

  describe "aggregations" do
    test "count and sum, and what a namespace with no documents reads as" do
      plan = plan(from c in CardStack, where: c.planbook_id == "x", select: {count(), count(c.id), sum(c.position)})

      assert plan.body == %{
               "aggregate_by" => %{"ecto_0" => ["Count"], "ecto_1" => ["Count"], "ecto_2" => ["Sum", "position"]},
               "filters" => ["planbook_id", "Eq", "x"]
             }

      assert Plan.page(plan, %{"aggregations" => %{"ecto_0" => 2, "ecto_1" => 2, "ecto_2" => 7}}) == {[[2, 2, 7]], nil}
      assert Plan.empty_page(plan) == {[[0, 0, nil]], nil}
    end

    test "group_by needs a limit, since turbopuffer returns at most 10,000 groups" do
      assert_raise Ecto.QueryError, ~r/at most 10000 groups, so add a limit/, fn ->
        plan(from c in CardStack, group_by: c.planbook_id, select: {c.planbook_id, count()})
      end

      plan = plan(from c in CardStack, group_by: c.planbook_id, select: {c.planbook_id, count()}, limit: 100)
      assert plan.body == %{"aggregate_by" => %{"ecto_1" => ["Count"]}, "group_by" => ["planbook_id"], "top_k" => 100}

      assert Plan.page(plan, %{"aggregation_groups" => [%{"planbook_id" => "a", "ecto_1" => 3}]}) == {[["a", 3]], nil}
      assert Plan.empty_page(plan) == {[], nil}
    end

    test "rejects what turbopuffer can't aggregate" do
      for {query, message} <- [
            {from(c in CardStack, select: count(c.title)), ~r/counts documents, so use count\(\) instead/},
            {from(c in CardStack, select: avg(c.position)), ~r/can't aggregate avg/},
            {from(c in CardStack, select: count(), order_by: c.position), ~r/can't order aggregations/},
            {from(c in CardStack, select: {c.title, count()}), ~r/select only aggregates and group_by fields/},
            {from(c in CardStack, group_by: c.title, select: c.title), ~r/group_by needs an aggregate/}
          ] do
        assert_raise Ecto.QueryError, message, fn -> plan(query) end
      end
    end
  end

  describe "union_all" do
    setup do
      text = from c in CardStack, order_by: [desc: bm25(c.markdown, ^"x")], limit: 2, select: {c.id, c.title}
      vector = from c in CardStack, order_by: ann(c.vector, ^[0.0, 0.0, 1.0]), limit: 2, select: {c.id, c.markdown}
      exact = from c in CardStack, order_by: knn(c.vector, ^[1.0, 0.0, 0.0]), limit: 3, select: {c.id, c.markdown}
      {:ok, text: text, vector: vector, exact: exact}
    end

    test "reads each leg's rows with its own selected fields", %{text: text, vector: vector} do
      plan = plan(union_all(text, ^vector))
      assert Enum.map(plan.body["queries"], & &1["include_attributes"]) == [["title"], ["markdown"]]

      response = %{
        "results" => [%{"rows" => [%{"id" => "a", "title" => "T"}]}, %{"rows" => [%{"id" => "b", "markdown" => "M"}]}]
      }

      assert Plan.page(plan, response) == {[["a", "T"], ["b", "M"]], nil}
    end

    test "flattens nested unions", %{text: text, vector: vector, exact: exact} do
      queries = body(union_all(text, ^union_all(vector, ^exact)))["queries"]
      assert Enum.map(queries, &Enum.at(&1["rank_by"], 1)) == ["BM25", "ANN", "kNN"]

      queries = body(text |> union_all(^vector) |> union_all(^exact))["queries"]
      assert Enum.map(queries, &Enum.at(&1["rank_by"], 1)) == ["BM25", "ANN", "kNN"]
    end

    test "runs against one namespace", %{text: text} do
      lesson = from l in Lesson, order_by: ann(l.markdown, embed(^"x")), limit: 2, select: {l.id, l.markdown}

      assert_raise Ecto.QueryError, ~r/a union_all runs against one namespace, not card_stacks, lessons/, fn ->
        plan(union_all(text, ^lesson))
      end

      assert_raise Ecto.QueryError, ~r/not card_stacks, other-card_stacks/, fn ->
        plan(union_all(text, ^put_query_prefix(text, "other")))
      end
    end

    test "rerank_by fuses the legs with RRF", %{text: text, vector: vector} do
      scored = fn query -> query |> exclude(:select) |> select([c], {c.id, dist()}) end
      plan = plan(union_all(scored.(text), ^scored.(vector)), rerank_by: :rrf)
      assert plan.kind == :fused
      assert plan.body["rerank_by"] == ["RRF"]

      fused = %{"results" => [%{"rows" => [%{"id" => "b", "$dist" => 0.03}, %{"id" => "a", "$dist" => 0.02}]}]}
      assert Plan.page(plan, fused) == {[["b", 0.03], ["a", 0.02]], nil}

      same = vector |> exclude(:select) |> select([c], {c.id, c.title})
      body = body(union_all(text, ^same), rerank_by: {:rrf, weights: [2, 1], rank_constant: 30, limit: 5, offset: 1})
      assert body["rerank_by"] == ["RRF", %{"weights" => [2, 1], "rank_constant" => 30}]
      assert {body["limit"], body["offset"]} == {5, 1}
    end

    test "checks rerank_by", %{text: text, vector: vector} do
      same = vector |> exclude(:select) |> select([c], {c.id, c.title})

      for {query, opts, message} <- [
            {union_all(text, ^same), [rerank_by: {:rrf, wieghts: [1, 5]}], ~r/unknown keys \[:wieghts\]/},
            {union_all(text, ^same), [rerank_by: {:rrf, weights: [1]}], ~r/one weight for each of the 2 searches/},
            {union_all(text, ^same), [rerank_by: {:rrf, limit: 10_000, offset: 1}], ~r/rerank_by: .*can't exceed/},
            {union_all(text, ^same), [rerank_by: :mmr], ~r/unknown :rerank_by :mmr/},
            {text, [rerank_by: :rrf], ~r/rerank_by fuses the searches of a union_all, but this query has only one/}
          ] do
        assert_raise ArgumentError, message, fn -> plan(query, opts) end
      end

      assert_raise Ecto.QueryError,
                   ~r/rerank_by fuses the searches into one list of rows, so they must select the same/,
                   fn ->
                     plan(union_all(text, ^vector), rerank_by: :rrf)
                   end
    end

    test "rejects what a multi-query can't run", %{text: text} do
      for {query, message} <- [
            {union_all(text, ^from(c in CardStack, select: {c.id, c.title})),
             ~r/each search in a union_all needs a limit/},
            {union_all(text, ^from(c in CardStack, select: count())), ~r/can't combine aggregations/},
            {union(text, ^text), ~r/can only combine searches with union_all, not union/},
            {Enum.reduce(1..16, text, fn _, acc -> union_all(acc, ^text) end), ~r/at most 16 queries in a union_all/}
          ] do
        assert_raise Ecto.QueryError, message, fn -> plan(query) end
      end
    end
  end

  test "consistency" do
    assert body(CardStack, consistency: :eventual)["consistency"] == %{"level" => "eventual"}

    assert_raise ArgumentError, ~r/:consistency must be :strong or :eventual/, fn ->
      plan(CardStack, consistency: :weak)
    end
  end

  test "unsupported query features" do
    for {query, message} <- [
          {from(c in CardStack, join: o in CardStack, on: o.id == c.id), ~r/no joins/},
          {from(c in CardStack, distinct: true), ~r/no distinct/},
          {from(c in subquery(from c in CardStack, limit: 1)), ~r/no subqueries/},
          {from(c in CardStack, order_by: c.position, limit: 1) |> with_ties(true), ~r/no limits with ties/}
        ] do
      assert_raise Ecto.QueryError, message, fn -> plan(query) end
    end
  end

  describe "update_all and delete_all" do
    defp write(operation, queryable) do
      {query, params} = planned(operation, queryable)
      apply(Plan, operation, [query, params])
    end

    test "update_all declares the schema, so new attributes get their types" do
      plan = write(:update_all, from(c in CardStack, where: c.planbook_id == "p1", update: [set: [title: ^"Moved"]]))

      assert %{"schema" => %{"title" => _}, "distance_metric" => "cosine_distance"} = plan.body

      assert plan.body["patch_by_filter"] == %{
               "filters" => ["planbook_id", "Eq", "p1"],
               "patch" => %{"title" => "Moved"}
             }

      assert write(:update_all, from(e in Everything, update: [set: [updated_at: ^~U[2026-01-01 00:00:00Z]]])).body[
               "patch_by_filter"
             ] == %{"filters" => ["id", "NotEq", nil], "patch" => %{"updated_at" => "2026-01-01T00:00:00.000Z"}}

      schemaless = write(:update_all, from(c in "card_stacks", update: [set: [title: "x"]]))

      assert schemaless.body == %{
               "patch_by_filter" => %{"filters" => ["id", "NotEq", nil], "patch" => %{"title" => "x"}}
             }
    end

    test "update_all can only set what turbopuffer can patch" do
      assert_raise ArgumentError, ~r/:vector can't be patched/, fn ->
        write(:update_all, from(c in CardStack, update: [set: [vector: ^[0.0, 1.0, 0.0]]]))
      end

      assert_raise Ecto.QueryError, ~r/can only `set` fields in update_all, not inc/, fn ->
        write(:update_all, from(c in CardStack, update: [inc: [position: 1]]))
      end
    end

    test "delete_all deletes by filter, declaring nothing" do
      assert write(:delete_all, from(c in CardStack, where: c.planbook_id == "p1")).body ==
               %{"delete_by_filter" => ["planbook_id", "Eq", "p1"]}

      assert write(:delete_all, CardStack).body == %{"delete_by_filter" => ["id", "NotEq", nil]}
      assert write(:delete_all, from(c in CardStack, where: false)).body == %{"delete_by_filter" => ["id", "Eq", nil]}
    end
  end

  describe "document writes" do
    setup do
      {:ok, ns: TP.Namespace.new(CardStack)}
    end

    test "upserts only insert new ids unless replacing every field", %{ns: ns} do
      rows = [[id: "a", title: "T", vector: "AAAA"]]

      assert [%Plan{kind: :write, namespace: "card_stacks", body: body}] =
               Plan.upserts(ns, "card_stacks", rows, {:raise, [], []}, nil)

      assert body == %{
               "schema" => ns.schema,
               "distance_metric" => "cosine_distance",
               "upsert_rows" => [%{"id" => "a", "title" => "T", "vector" => "AAAA"}],
               "upsert_condition" => ["id", "Eq", nil],
               "return_affected_ids" => true
             }

      [%{body: body}] = Plan.upserts(ns, "card_stacks", rows, {:nothing, [], []}, nil)
      assert {body["upsert_condition"], body["return_affected_ids"]} == {["id", "Eq", nil], nil}

      all = CardStack.__schema__(:fields) -- [:id]
      [%{body: body}] = Plan.upserts(ns, "card_stacks", rows, {all, [], []}, nil)
      refute Map.has_key?(body, "upsert_condition")

      assert_raise ArgumentError, ~r/must replace every field, e.g. :replace_all. It leaves out \["markdown"/, fn ->
        Plan.upserts(ns, "card_stacks", rows, {[:title], [], []}, nil)
      end

      assert_raise ArgumentError, ~r/can't run an update on conflict/, fn ->
        Plan.upserts(ns, "card_stacks", rows, {%Ecto.Query{}, [], []}, nil)
      end
    end

    test "upserts go in batches of 1,000, or 30 with native embedding", %{ns: ns} do
      rows = for i <- 1..1_001, do: [id: "#{i}", vector: "AAAA"]

      assert ns |> Plan.upserts("n", rows, {:nothing, [], []}, nil) |> Enum.map(&length(&1.body["upsert_rows"])) == [
               1_000,
               1
             ]

      assert ns |> Plan.upserts("n", Enum.take(rows, 5), {:nothing, [], []}, 2) |> length() == 3

      lessons = for i <- 1..31, do: [id: "#{i}", markdown: "m"]
      assert Lesson |> TP.Namespace.new() |> Plan.upserts("n", lessons, {:nothing, [], []}, nil) |> length() == 2
    end

    test "update patches one document, checking any other filters", %{ns: ns} do
      body = Plan.update(ns, "n", [title: "Decimals"], id: "a").body
      assert body["patch_rows"] == [%{"id" => "a", "title" => "Decimals"}]
      assert body["schema"] == ns.schema
      refute Map.has_key?(body, "patch_condition")

      assert Plan.update(ns, "n", [title: "Decimals"], id: "a", position: 1).body["patch_condition"] ==
               ["position", "Eq", 1]
    end

    test "delete counts only a document that exists" do
      assert Plan.delete("n", id: "a").body == %{"deletes" => ["a"], "delete_condition" => ["id", "NotEq", nil]}

      assert Plan.delete("n", id: "a", position: 1).body["delete_condition"] ==
               ["And", [["id", "NotEq", nil], ["position", "Eq", 1]]]
    end
  end
end
