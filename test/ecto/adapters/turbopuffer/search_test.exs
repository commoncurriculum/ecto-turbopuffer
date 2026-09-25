defmodule Ecto.Adapters.Turbopuffer.SearchTest do
  use TP.Test.Case, async: true

  alias TP.Test.{CardStack, Everything}

  setup do
    Repo.insert_all(CardStack, [
      %{
        id: "photosynthesis",
        title: "Photosynthesis",
        markdown: "How plants turn sunlight, water and carbon dioxide into sugar.",
        planbook_id: "science",
        position: 1,
        vector: [1.0, 0.0, 0.0]
      },
      %{
        id: "cells",
        title: "Cell division",
        markdown: "Mitosis splits one cell into two. Plants and animals both grow this way.",
        planbook_id: "science",
        position: 2,
        vector: [0.9, 0.1, 0.0]
      },
      %{
        id: "revolution",
        title: "The French Revolution",
        markdown: "The storming of the Bastille in 1789.",
        planbook_id: "history",
        position: 3,
        vector: [0.0, 0.0, 1.0]
      }
    ])

    :ok
  end

  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id)

  describe "full-text search" do
    test "bm25 ranks by relevance, and dist() selects the score" do
      assert [{"photosynthesis", score}, {"cells", _}] =
               Repo.all(
                 from c in CardStack,
                   order_by: [desc: bm25(c.markdown, ^"plants sugar")],
                   limit: 10,
                   select: {c.id, dist()}
               )

      assert score > 0
    end

    test "sums, weights, and takes the max of scores" do
      query =
        from c in CardStack, order_by: [desc: bm25(c.markdown, ^"cell") + 3.0 * bm25(c.title, ^"revolution")], limit: 2

      assert ids(query) == ~w(revolution cells)

      query =
        from c in CardStack, order_by: [desc: max_score(bm25(c.title, "cell"), bm25(c.markdown, "bastille"))], limit: 3

      assert Enum.sort(ids(query)) == ~w(cells revolution)
    end

    test "last_as_prefix matches the last word as a prefix, for type-ahead" do
      prefix = %{last_as_prefix: true}
      assert ids(from c in CardStack, order_by: [desc: bm25(c.markdown, ^"mito", ^prefix)], limit: 5) == ~w(cells)
      assert ids(from c in CardStack, where: contains_all_tokens(c.markdown, ^"plants mito", ^prefix)) == ~w(cells)
      assert ids(from c in CardStack, where: contains_any_token(c.markdown, ^"bast", ^prefix)) == ~w(revolution)
    end

    test "follows each field's tokenizer, language, and case and accent settings" do
      Repo.insert!(
        Everything.new(id: "a", title: "Photosynthesis in plants", summary: "Noël", tokens: ["self-evident"])
      )

      Repo.insert!(Everything.new(id: "b", title: "A plant cell", summary: "noel", tokens: ["self", "evident"]))

      # English stemming matches "plant" to "plants".
      assert Enum.sort(ids(from e in Everything, where: contains_all_tokens(e.title, "plant"))) == ~w(a b)

      # summary folds accents but is case-sensitive.
      assert ids(from e in Everything, where: contains_all_tokens(e.summary, "Noel")) == ~w(a)
      assert ids(from e in Everything, where: contains_all_tokens(e.summary, "noel")) == ~w(b)

      # A pre-tokenized field takes lists of tokens and matches them exactly.
      assert ids(from e in Everything, order_by: [desc: bm25(e.tokens, ^["self-evident"])], limit: 5) == ~w(a)
      assert ids(from e in Everything, where: contains_all_tokens(e.tokens, ^["self", "evident"])) == ~w(b)
    end
  end

  describe "scoring by attributes and filters" do
    setup do
      Repo.insert_all(
        Everything,
        for {id, views, position, updated_at} <- [
              {"old", 10, -5, ~U[2026-01-01 00:00:00Z]},
              {"popular", 1_000, 5, ~U[2026-02-01 00:00:00Z]},
              {"recent", 100, 1, ~U[2026-02-03 00:00:00Z]}
            ] do
          %{id: id, views: views, position: position, updated_at: updated_at, title: "quick fox #{id}"}
          |> Map.merge(%{embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [1, 0]})
        end
      )

      :ok
    end

    defp scored(order_by) do
      Repo.all(from e in Everything, order_by: ^[desc: order_by], limit: 5, select: {e.id, dist()})
    end

    test "attribute/1 scores a number, and a signed number's negatives as 0" do
      assert [{"popular", 1_000.0}, {"recent", 100.0}, {"old", 10.0}] = scored(dynamic([e], attribute(e.views)))
      assert [{"popular", 5.0}, {"recent", 1.0}, {"old", 0.0}] = scored(dynamic([e], attribute(e.position)))

      assert [{"popular", 5.0}, {"recent", 1.0}, {"old", 0.0}] =
               scored(dynamic([e], max_score(0, attribute(e.position))))

      assert Enum.sort(scored(dynamic([e], max_score(2, attribute(e.position))))) ==
               [{"old", 2.0}, {"popular", 5.0}, {"recent", 2.0}]
    end

    test "saturate and decay map scores into 0..1 around a midpoint" do
      assert [{"popular", popular}, {"recent", 0.5}, {"old", _}] =
               scored(dynamic([e], saturate(attribute(e.views), 100)))

      assert_in_delta popular, 1_000 / 1_100, 0.0001

      assert [{"popular", steeper}, {"recent", 0.5} | _] = scored(dynamic([e], saturate(attribute(e.views), 100, 2)))
      assert steeper > popular

      assert [{"old", old}, {"recent", 0.5}, {"popular", _}] = scored(dynamic([e], decay(attribute(e.views), 100)))
      assert_in_delta old, 100 / 110, 0.0001
    end

    test "distance/2 scores how far a number or datetime is from an origin" do
      now = ~U[2026-02-03 00:00:00Z]

      assert [{"recent", 1.0}, {"popular", _}, {"old", _}] =
               scored(dynamic([e], decay(distance(e.updated_at, ^now), "6h")))

      assert [{"recent", 1.0} | _] = scored(dynamic([e], decay(distance(e.updated_at, ^now), 21_600_000)))
      assert [{"popular", 900.0}, {"old", 90.0}, {"recent", 0.0}] = scored(dynamic([e], distance(e.views, 100)))
    end

    test "a filter scores 1 where it matches, so it boosts documents or ranks them alone" do
      assert [{"popular", _}, {"old", _}, {"recent", _}] =
               scored(dynamic([e], bm25(e.title, "fox") + 2.0 * (e.id == "popular") + (e.views < 50)))

      # Unlike an attribute or distance, a filter that scores 0 leaves the document out.
      assert [{"recent", 1.0}] = scored(dynamic([e], e.views == 100))
      assert [{"old", 3.0}] = scored(dynamic([e], 3 * regex(e.title, "old$")))
    end

    test "a select computes any score but a vector search for each row, and a filter as a boolean" do
      assert [{"old", old, false, 0.0}, {"recent", 0.5, true, 1.0}] =
               Repo.all(
                 from e in Everything,
                   where: e.id in ["recent", "old"],
                   select: {e.id, saturate(attribute(e.views), 100), e.views > 50, attribute(e.position)}
               )

      assert_in_delta old, 10 / 110, 0.0001
    end
  end

  describe "highlight" do
    setup do
      Repo.insert!(%CardStack{
        id: "fox",
        title: "The quick brown fox jumps. Then it sleeps in the sun. Foxes are clever.",
        vector: [1.0, 0.0, 0.0]
      })

      :ok
    end

    test "selects the fragments that match the query's bm25" do
      assert [{"fox", [%{"text" => "The quick brown fox jumps."} | _]}] =
               Repo.all(
                 from c in CardStack,
                   order_by: [desc: bm25(c.title, ^"fox")],
                   limit: 1,
                   select: {c.id, highlight(c.title)}
               )
    end

    test "takes turbopuffer's options, which a query not ranked by the field's bm25 needs" do
      options = %{
        fragment_by: "word",
        fragment_limit: 1,
        include_offsets: "codepoints",
        rank_fragments_by: ["$fragment", "BM25", "sun"]
      }

      assert [[%{"text" => "sun", "fragment_range" => [start, stop], "match_ranges" => [[start, stop]]}]] =
               Repo.all(from c in CardStack, where: c.id == "fox", select: highlight(c.title, ^options))

      assert stop - start == 3
    end
  end

  describe "vector search" do
    test "ranks f32, f16 and i8 vectors, reading them back as base64" do
      Repo.insert_all(Everything, [
        %{id: "x", embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [127, 0]},
        %{id: "y", embedding: [0.0, 1.0, 0.0], half_embedding: [0.0, 1.0], small_embedding: [0, -128]}
      ])

      for query <- [
            from(e in Everything, order_by: ann(e.embedding, ^[0.0, 0.9, 0.1]), limit: 2, select: {e.id, e.embedding}),
            from(e in Everything,
              order_by: ann(e.half_embedding, ^[0.1, 0.9]),
              limit: 2,
              select: {e.id, e.half_embedding}
            ),
            from(e in Everything,
              order_by: ann(e.small_embedding, ^[0, -100]),
              limit: 2,
              select: {e.id, e.small_embedding}
            )
          ] do
        {rows, [request]} = requests(fn -> Repo.all(query) end)
        assert request.query["vector_encoding"] == "base64"
        assert [{"y", _}, {"x", _}] = rows
      end

      assert [{"y", [0, -128]}, {"x", [127, 0]}] =
               Repo.all(
                 from e in Everything,
                   order_by: ann(e.small_embedding, ^[0, -1]),
                   limit: 2,
                   select: {e.id, e.small_embedding}
               )
    end

    test "knn ranks exactly within a filter, and vector_distance selects a distance" do
      exact =
        from c in CardStack, where: c.planbook_id == "history", order_by: knn(c.vector, ^[1.0, 0.0, 0.0]), limit: 2

      assert ids(exact) == ~w(revolution)

      assert [{"photosynthesis", distance}] =
               Repo.all(
                 from c in CardStack,
                   where: c.id == "photosynthesis",
                   select: {c.id, vector_distance(c.vector, ^[0.0, 1.0, 0.0])}
               )

      assert_in_delta distance, 1.0, 0.0001
    end

    test "sparse_knn ranks sparse vectors by dot product" do
      Repo.insert_all(Everything, [
        Map.merge(Map.take(Everything.new([]), [:embedding, :half_embedding, :small_embedding]), %{
          id: "a",
          sparse: %{"1" => 1.0}
        }),
        Map.merge(Map.take(Everything.new([]), [:embedding, :half_embedding, :small_embedding]), %{
          id: "b",
          sparse: %{"1" => 0.2, "2" => 1.0}
        })
      ])

      assert [{"a", a}, {"b", b}] =
               Repo.all(
                 from e in Everything,
                   order_by: [desc: sparse_knn(e.sparse, ^%{"1" => 1.0})],
                   limit: 2,
                   select: {e.id, dist()}
               )

      assert_in_delta a, 1.0, 0.01
      assert_in_delta b, 0.2, 0.01
    end
  end

  describe "union_all" do
    setup do
      text = from c in CardStack, order_by: [desc: bm25(c.markdown, ^"sunlight")], limit: 2
      vector = from c in CardStack, order_by: ann(c.vector, ^[0.0, 0.0, 1.0]), limit: 1
      {:ok, text: text, vector: vector}
    end

    test "runs a multi-query, with each search's own ordering, limit and selected fields", %{text: text, vector: vector} do
      assert ids(union_all(text, ^vector)) == ~w(photosynthesis revolution)

      assert Repo.all(union_all(select(text, [c], {c.id, c.title}), ^select(vector, [c], {c.id, c.planbook_id}))) ==
               [{"photosynthesis", "Photosynthesis"}, {"revolution", "history"}]

      exact =
        from c in CardStack, where: c.planbook_id == "science", order_by: knn(c.vector, ^[0.0, 1.0, 0.0]), limit: 1

      assert ids(union_all(text, ^union_all(vector, ^exact))) == ~w(photosynthesis revolution cells)
    end

    test "rerank_by: :rrf fuses the searches into one ranking", %{text: text, vector: vector} do
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
    end
  end
end
