defmodule Ecto.Adapters.Turbopuffer.QueryTest do
  use TP.Test.Case, async: true

  alias TP.Test.{CardStack, Everything}

  setup do
    Repo.insert_all(CardStack, [
      %{
        id: "photosynthesis",
        title: "Photosynthesis",
        markdown: "How plants turn sunlight, water and carbon dioxide into sugar.",
        planbook_id: "science",
        standard_ids: ["LS1.C"],
        position: 1,
        vector: [1.0, 0.0, 0.0]
      },
      %{
        id: "cells",
        title: "Cell division",
        markdown: "Mitosis splits one cell into two. Plants and animals both grow this way.",
        planbook_id: "science",
        standard_ids: ["LS1.B", "LS1.C"],
        position: 2,
        vector: [0.9, 0.1, 0.0]
      },
      %{
        id: "revolution",
        title: "The French Revolution",
        markdown: "The storming of the Bastille in 1789.",
        planbook_id: "history",
        standard_ids: [],
        position: 3,
        vector: [0.0, 0.0, 1.0]
      },
      %{
        id: "fractions",
        title: "Fractions",
        markdown: "Halves, thirds and quarters.",
        planbook_id: nil,
        standard_ids: ["3.NF.A.1"],
        position: 4,
        vector: [0.0, 1.0, 0.0]
      }
    ])

    :ok
  end

  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id)

  describe "filters" do
    test "comparisons, in, and nil checks" do
      assert ids(from c in CardStack, where: c.planbook_id == "science") == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.planbook_id != "science") == ~w(fractions revolution)
      assert ids(from c in CardStack, where: c.position > 2) == ~w(fractions revolution)
      assert ids(from c in CardStack, where: 2 >= c.position) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.id in ^["cells", "fractions"]) == ~w(cells fractions)
      assert ids(from c in CardStack, where: c.id not in ["cells", "fractions"]) == ~w(photosynthesis revolution)
      assert ids(from c in CardStack, where: is_nil(c.planbook_id)) == ~w(fractions)

      assert ids(from c in CardStack, where: not is_nil(c.planbook_id), where: c.position < 3) ==
               ~w(cells photosynthesis)
    end

    test "datetimes, uuids, and bools" do
      vectors = %{embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [1, 0]}
      uuid = "769c134d-07b8-4225-954a-b6cc5ffc320c"

      Repo.insert_all(Everything, [
        Map.merge(vectors, %{id: "old", updated_at: ~U[2025-01-01 00:00:00Z], owner_uuid: uuid, is_public: true}),
        Map.merge(vectors, %{id: "new", updated_at: ~U[2026-09-01 00:00:00Z], is_public: false})
      ])

      assert ids(from e in Everything, where: e.updated_at > ^~U[2026-01-01 00:00:00Z]) == ~w(new)
      assert ids(from e in Everything, where: e.owner_uuid == ^uuid) == ~w(old)
      assert ids(from e in Everything, where: e.is_public == false) == ~w(new)
      assert ids(from e in Everything, order_by: [desc: e.updated_at], limit: 1) == ~w(new)
    end

    test "ordering comparisons never match nil, and != does" do
      Repo.insert!(%CardStack{id: "unpositioned", vector: [1.0, 0.0, 0.0]})

      assert ids(from c in CardStack, where: c.position < 3) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.position <= 2) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: not (c.position > 2)) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: not (c.position >= 3)) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.position > 3) == ~w(fractions)
      assert ids(from c in CardStack, where: c.position != 1) == ~w(cells fractions revolution unpositioned)
    end

    test "dynamic(true) seeds a filter" do
      filter = dynamic([c], ^dynamic(true) and c.planbook_id == ^"science")
      assert ids(from c in CardStack, where: ^filter) == ~w(cells photosynthesis)
    end

    test "and, or, and not" do
      query = from c in CardStack, where: c.planbook_id == "history" or (c.position == 1 and not (c.title == "Cells"))
      assert ids(query) == ~w(photosynthesis revolution)

      query = from c in CardStack, where: c.planbook_id == "history", or_where: c.id == "fractions"
      assert ids(query) == ~w(fractions revolution)
    end

    test "a leading or_where filters, and not distributes over and" do
      assert ids(from c in CardStack, or_where: c.id == "cells") == ~w(cells)

      query = Enum.reduce(~w(cells revolution), CardStack, fn id, query -> or_where(query, [c], c.id == ^id) end)
      assert ids(query) == ~w(cells revolution)

      # != matches nil, so fractions, with no planbook, is in.
      assert ids(from c in CardStack, where: not (c.planbook_id == "science" and c.position > 1)) ==
               ~w(fractions photosynthesis revolution)
    end

    test "arrays" do
      assert ids(from c in CardStack, where: contains(c.standard_ids, "LS1.C")) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: contains(c.standard_ids, ^"LS1.B")) == ~w(cells)
      assert ids(from c in CardStack, where: not contains(c.standard_ids, "LS1.C")) == ~w(fractions revolution)

      assert ids(from c in CardStack, where: contains_any(c.standard_ids, ^["LS1.B", "3.NF.A.1"])) ==
               ~w(cells fractions)

      assert ids(from c in CardStack, where: any_gte(c.standard_ids, "LS1.C")) == ~w(cells photosynthesis)

      # Ecto only allows `value in field` on its own array types, so a schemaless query shows Contains/NotContains.
      schemaless = fn where -> Repo.all(from(c in "card_stacks", select: c.id, order_by: c.id) |> where(^where)) end
      assert schemaless.(dynamic([c], "LS1.B" in c.standard_ids)) == ~w(cells)
      assert schemaless.(dynamic([c], "LS1.C" not in c.standard_ids)) == ~w(fractions revolution)
    end

    test "like and ilike become globs" do
      assert ids(from c in CardStack, where: like(c.title, "Photo%")) == ~w(photosynthesis)
      assert ids(from c in CardStack, where: ilike(c.title, ^"%REVOLUTION")) == ~w(revolution)
      assert ids(from c in CardStack, where: like(c.title, "Fraction_")) == ~w(fractions)
      assert ids(from c in CardStack, where: not like(c.title, "Photo%")) == ~w(cells fractions revolution)
      assert ids(from c in CardStack, where: like(c.id, "photo%")) == ~w(photosynthesis)
      assert ids(from c in CardStack, where: iglob(c.title, "the french*")) == ~w(revolution)
    end

    test "regex" do
      vectors = %{embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [1, 0]}

      Repo.insert_all(Everything, [
        Map.merge(vectors, %{id: "a", title: "Photosynthesis in plants"}),
        Map.merge(vectors, %{id: "b", title: "Cell division"})
      ])

      assert ids(from e in Everything, where: regex(e.title, "^Photo.*plants$")) == ~w(a)
    end

    test "text filters" do
      assert ids(from c in CardStack, where: fuzzy(c.title, ^"fotosynthesis")) == ~w(photosynthesis)
      assert ids(from c in CardStack, where: contains_all_tokens(c.markdown, ^"plants sugar")) == ~w(photosynthesis)

      assert ids(from c in CardStack, where: contains_any_token(c.markdown, ^"mitosis bastille")) ==
               ~w(cells revolution)

      assert ids(from c in CardStack, where: contains_token_sequence(c.markdown, ^"one cell into two")) == ~w(cells)

      assert ids(from c in CardStack, where: contains_all_tokens(c.markdown, ^"mito", ^%{last_as_prefix: true})) ==
               ~w(cells)

      strict = %{max_edit_distance: [%{min_query_chars: 3, distance: 0}]}
      assert ids(from c in CardStack, where: fuzzy(c.title, ^"fotosynthesis", ^strict)) == []
    end

    test "check the schema's indexes before sending" do
      assert_raise Ecto.QueryError, ~r/:markdown isn't filterable in TP.Test.CardStack/, fn ->
        Repo.all(from c in CardStack, where: c.markdown == "x")
      end

      assert_raise Ecto.QueryError, ~r/:planbook_id needs `full_text_search:` in TP.Test.CardStack/, fn ->
        Repo.all(from c in CardStack, order_by: [desc: bm25(c.planbook_id, "x")], limit: 1)
      end

      assert_raise Ecto.QueryError, ~r/:markdown needs `fuzzy:`/, fn ->
        Repo.all(from c in CardStack, where: fuzzy(c.markdown, "x"))
      end
    end
  end

  describe "ordering and limits" do
    test "by fields" do
      assert ids(from c in CardStack, order_by: [desc: c.position], limit: 10) ==
               ~w(fractions revolution cells photosynthesis)

      assert ids(from c in CardStack, order_by: [c.planbook_id, desc: c.position], limit: 3) ==
               ~w(fractions revolution cells)

      assert ids(from c in CardStack, order_by: c.position, limit: 2, offset: 1) == ~w(cells revolution)
    end

    test "unordered queries without a limit page through every row, and others need one" do
      assert length(Repo.all(CardStack)) == 4
      assert Enum.count(Repo.stream(CardStack)) == 4

      assert_raise Ecto.QueryError, ~r/at most 10000 results per query, so add a limit/, fn ->
        Repo.all(from c in CardStack, order_by: c.position)
      end

      assert_raise Ecto.QueryError, ~r/nulls first ascending and last descending/, fn ->
        Repo.all(from c in CardStack, order_by: [asc_nulls_last: c.position], limit: 1)
      end
    end

    test "each page after the first filters past the previous page's last id" do
      rows =
        for i <- 1..10_001 do
          %{id: "p" <> String.pad_leading("#{i}", 5, "0"), position: 100 + i, vector: [1.0, 0.0, 0.0]}
        end

      Repo.insert_all(CardStack, rows)
      handler = inspect(self())
      :telemetry.attach(handler, [:tp, :test, :repo, :query], &__MODULE__.send_query/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)

      assert ids(from c in CardStack, where: c.position > 100, order_by: [desc: c.id]) ==
               rows |> Enum.map(& &1.id) |> Enum.reverse()

      assert_received {:query, %{"filters" => ["position", "Gt", 100]}}
      assert_received {:query, %{"filters" => ["And", [["position", "Gt", 100], ["id", "Lt", "p00002"]]]}}
    end
  end

  describe "selects and aggregates" do
    test "select fields" do
      assert Repo.all(from c in CardStack, where: c.id == "fractions", select: {c.id, c.title, c.position}) ==
               [{"fractions", "Fractions", 4}]

      assert Repo.one(from c in CardStack, where: c.id == "fractions", select: %{title: c.title}) == %{
               title: "Fractions"
             }
    end

    test "count, sum, group_by, and exists?" do
      assert Repo.aggregate(CardStack, :count) == 4
      assert Repo.aggregate(from(c in CardStack, where: c.planbook_id == "science"), :count, :id) == 2
      assert Repo.aggregate(CardStack, :sum, :position) == 10

      query = from c in CardStack, group_by: c.planbook_id, select: {c.planbook_id, count(), sum(c.position)}, limit: 10
      assert Enum.sort(Repo.all(query)) == [{nil, 1, 4}, {"history", 1, 3}, {"science", 2, 3}]

      assert Repo.exists?(from c in CardStack, where: c.planbook_id == "history")
      refute Repo.exists?(from c in CardStack, where: c.planbook_id == "art")

      assert_raise Ecto.QueryError, ~r/counts documents, so use count\(\)/, fn ->
        Repo.aggregate(CardStack, :count, :title)
      end
    end

    test "schemaless queries send field names as they are" do
      assert Repo.all(from c in "card_stacks", where: c.planbook_id == "history", select: {c.id, c.position}) ==
               [{"revolution", 3}]
    end
  end

  describe "search" do
    test "bm25, with dist() for the score" do
      [{first, score} | _] =
        Repo.all(
          from c in CardStack,
            order_by: [desc: bm25(c.markdown, ^"plants sugar")],
            limit: 10,
            select: {c, dist()}
        )

      assert first.id == "photosynthesis"
      assert is_float(score) and score > 0

      assert_raise Ecto.QueryError, ~r/highest scores first, so order it desc/, fn ->
        Repo.all(from c in CardStack, order_by: bm25(c.markdown, "plants"), limit: 1)
      end
    end

    test "sums, weights, and max of bm25 scores" do
      query =
        from c in CardStack,
          order_by: [desc: bm25(c.markdown, ^"cell") + 3.0 * bm25(c.title, ^"revolution")],
          limit: 2

      assert ids(query) == ~w(revolution cells)

      query =
        from c in CardStack, order_by: [desc: max_score(bm25(c.title, "cell"), bm25(c.markdown, "bastille"))], limit: 2

      assert Enum.sort(ids(query)) == ~w(cells revolution)

      # last_as_prefix makes the last word match as a prefix, for type-ahead.
      query = from c in CardStack, order_by: [desc: bm25(c.markdown, ^"mito", ^%{last_as_prefix: true})], limit: 1
      assert ids(query) == ~w(cells)
    end

    test "bm25 in a select computes the score without ranking by it" do
      [{id, score}] =
        Repo.all(from c in CardStack, where: c.id == "cells", select: {c.id, bm25(c.markdown, ^"mitosis")}, limit: 1)

      assert id == "cells" and score > 0
    end

    test "vector search" do
      assert ids(from c in CardStack, order_by: ann(c.vector, ^[1.0, 0.05, 0.0]), limit: 2) == ~w(photosynthesis cells)

      assert ids(
               from c in CardStack,
                 where: c.planbook_id == "history",
                 order_by: knn(c.vector, ^[1.0, 0.0, 0.0]),
                 limit: 2
             ) ==
               ~w(revolution)

      [{"photosynthesis", distance}] =
        Repo.all(
          from c in CardStack,
            where: c.id == "photosynthesis",
            select: {c.id, vector_distance(c.vector, ^[0.0, 1.0, 0.0])},
            limit: 1
        )

      assert_in_delta distance, 1.0, 0.0001

      assert_raise Ecto.QueryError, ~r/vector search ranks the closest vectors first, so order it asc/, fn ->
        Repo.all(from c in CardStack, order_by: [desc: ann(c.vector, ^[1.0, 0.0, 0.0])], limit: 1)
      end
    end

    test "sparse vector search" do
      Repo.insert_all(Everything, [
        %{
          id: "a",
          embedding: [1.0, 0.0, 0.0],
          half_embedding: [1.0, 0.0],
          small_embedding: [1, 0],
          sparse: %{"1" => 1.0}
        },
        %{
          id: "b",
          embedding: [1.0, 0.0, 0.0],
          half_embedding: [1.0, 0.0],
          small_embedding: [1, 0],
          sparse: %{"1" => 0.2, "2" => 1.0}
        }
      ])

      query =
        from e in Everything, order_by: [desc: sparse_knn(e.sparse, ^%{"1" => 1.0})], limit: 2, select: {e.id, dist()}

      assert [{"a", a}, {"b", b}] = Repo.all(query)
      assert a > b
    end

    test "union_all runs a multi-query, and rerank_by: :rrf fuses it" do
      text = from c in CardStack, order_by: [desc: bm25(c.markdown, ^"sunlight")], limit: 2
      vector = from c in CardStack, order_by: ann(c.vector, ^[0.0, 0.0, 1.0]), limit: 1

      assert ids(union_all(text, ^vector)) == ~w(photosynthesis revolution)

      assert Repo.all(union_all(select(text, [c], {c.id, c.title}), ^select(vector, [c], {c.id, c.planbook_id}))) ==
               [{"photosynthesis", "Photosynthesis"}, {"revolution", "history"}]

      scored = fn query -> select(query, [c], {c.id, dist()}) end
      assert [{_, rrf} | _] = Repo.all(union_all(scored.(text), ^scored.(vector)), rerank_by: :rrf)
      assert_in_delta rrf, 1 / 61, 0.0001

      top = fn weights -> Repo.all(union_all(text, ^vector), rerank_by: {:rrf, weights: weights, limit: 1}) end
      assert Enum.map(top.([5, 1]), & &1.id) == ~w(photosynthesis)
      assert Enum.map(top.([1, 5]), & &1.id) == ~w(revolution)

      # Each row scores weight / (rank_constant + rank), and offset skips the first fused row.
      fused =
        Repo.all(union_all(scored.(text), ^scored.(vector)),
          rerank_by: {:rrf, weights: [2, 1], rank_constant: 10, limit: 1, offset: 1}
        )

      assert [{"revolution", second}] = fused
      assert_in_delta second, 1 / 11, 0.0001

      assert_raise ArgumentError, ~r/unknown keys \[:wieghts\]/, fn ->
        Repo.all(union_all(text, ^vector), rerank_by: {:rrf, wieghts: [1, 5]})
      end
    end
  end

  test "consistency: :eventual" do
    assert length(Repo.all(CardStack, consistency: :eventual)) in 0..4
  end

  def send_query(_event, _measurements, %{query: body}, test) do
    if self() == test, do: send(test, {:query, body})
  end
end
