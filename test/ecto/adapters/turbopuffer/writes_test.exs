defmodule Ecto.Adapters.Turbopuffer.WritesTest do
  use TP.Test.Case, async: true

  alias TP.Test.{CardStack, Everything, Lesson, ReviewedCardStack}

  defp card_stack(id, attrs \\ []) do
    struct(%CardStack{id: id, title: "Fractions", position: 1, vector: [1.0, 0.0, 0.0]}, attrs)
  end

  defp ids(queryable), do: queryable |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  describe "insert" do
    test "won't overwrite an existing id by default" do
      assert {:ok, _} = Repo.insert(card_stack("a", markdown: "# Fractions"))

      changeset = card_stack("a", title: "Decimals") |> Ecto.Changeset.change() |> Ecto.Changeset.unique_constraint(:id)
      assert {:error, changeset} = Repo.insert(changeset)
      assert {"has already been taken", _} = changeset.errors[:id]

      assert_raise Ecto.ConstraintError, ~r/"card_stacks_id_index" \(unique_constraint\)/, fn ->
        Repo.insert(card_stack("a", title: "Decimals"))
      end

      assert %CardStack{title: "Fractions", markdown: "# Fractions"} = Repo.get!(CardStack, "a")
    end

    test "on_conflict: :nothing skips an existing id and :replace_all overwrites it" do
      Repo.insert!(card_stack("a", markdown: "# Fractions"))

      Repo.insert!(card_stack("a", title: "Decimals"), on_conflict: :nothing)
      assert Repo.get!(CardStack, "a").title == "Fractions"

      Repo.insert!(card_stack("a", title: "Decimals"), on_conflict: :replace_all)
      assert %CardStack{title: "Decimals", markdown: nil} = Repo.get!(CardStack, "a")
    end

    test "replace_if replaces an existing document only when it matches, comparing it to ref_new/1" do
      newer = dynamic([e], e.updated_at < ref_new(e.updated_at))
      write = fn id, at, title -> Everything.new(id: id, updated_at: at, title: title) end

      Repo.insert!(write.("a", ~U[2026-01-02 00:00:00Z], "Current"))
      Repo.insert!(write.("a", ~U[2026-01-01 00:00:00Z], "Stale"), on_conflict: :replace_all, replace_if: newer)
      assert Repo.get!(Everything, "a").title == "Current"

      Repo.insert!(write.("a", ~U[2026-01-03 00:00:00Z], "Newer"), on_conflict: :replace_all, replace_if: newer)
      assert Repo.get!(Everything, "a").title == "Newer"

      # A document that doesn't exist yet is written whatever the condition.
      rows = [
        %{id: "a", updated_at: ~U[2026-01-01 00:00:00Z], title: "Stale"},
        %{id: "b", updated_at: ~U[2026-01-01 00:00:00Z], title: "New"}
      ]

      rows =
        Enum.map(
          rows,
          &Map.merge(&1, %{embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [1, 0]})
        )

      assert Repo.insert_all(Everything, rows, on_conflict: :replace_all, replace_if: newer) == {1, nil}
      assert Repo.all(from e in Everything, order_by: e.id, select: {e.id, e.title}) == [{"a", "Newer"}, {"b", "New"}]
    end

    test "needs every vector" do
      assert_raise ArgumentError, ~r/without :vector: turbopuffer upserts must include every vector/, fn ->
        Repo.insert(card_stack("a", vector: nil))
      end
    end

    test "stores uuid ids lowercased, and autogenerates them" do
      Repo.insert!(%Lesson{id: "769C134D-07B8-4225-954A-B6CC5FFC320C", markdown: "Fractions on a number line."})
      assert Repo.get!(Lesson, "769c134d-07b8-4225-954a-b6cc5ffc320c").markdown == "Fractions on a number line."
      assert Repo.get!(Lesson, "769C134D-07B8-4225-954A-B6CC5FFC320C").id == "769c134d-07b8-4225-954a-b6cc5ffc320c"

      assert {:ok, _} = Ecto.UUID.cast(Repo.insert!(%Lesson{markdown: "Halves and quarters."}).id)
    end
  end

  describe "insert_all" do
    test "writes documents in batches of :batch_size" do
      rows = for i <- 1..5, do: %{id: "cs#{i}", title: {:placeholder, :title}, position: i, vector: [1.0, 0.0, 0.0]}

      {result, writes} =
        requests(fn -> Repo.insert_all(CardStack, rows, batch_size: 2, placeholders: %{title: "Shared"}) end)

      assert result == {5, nil}
      assert Enum.map(writes, &length(&1.query["upsert_rows"])) == [2, 2, 1]
      assert Repo.all(from c in CardStack, select: {c.id, c.title}) == for(i <- 1..5, do: {"cs#{i}", "Shared"})
    end

    test "handles existing ids by on_conflict, raising TP.ConflictError by default" do
      rows = [%{id: "a", title: "One", vector: [1.0, 0.0, 0.0]}, %{id: "b", title: "Two", vector: [1.0, 0.0, 0.0]}]
      Repo.insert_all(CardStack, Enum.take(rows, 1))

      error = assert_raise TP.ConflictError, fn -> Repo.insert_all(CardStack, rows) end
      assert error.ids == ["a"]
      assert Exception.message(error) =~ ~r/1 of 2 ids already exist in ecto-tpuf-test-\w+-card_stacks/
      assert Repo.get!(CardStack, "a").title == "One"
      assert Repo.get!(CardStack, "b").title == "Two"

      assert Repo.insert_all(CardStack, rows, on_conflict: :nothing) == {0, nil}

      renamed = Enum.map(rows, &%{&1 | title: "Renamed"})
      assert Repo.insert_all(CardStack, renamed, on_conflict: :replace_all) == {2, nil}
      assert Enum.map(Repo.all(CardStack), & &1.title) == ["Renamed", "Renamed"]
    end

    test "disable_backpressure writes without turbopuffer's backpressure, for bulk loads" do
      rows = for i <- 1..3, do: %{id: "cs#{i}", vector: [1.0, 0.0, 0.0]}

      {result, [write]} =
        requests(fn -> Repo.insert_all(CardStack, rows, on_conflict: :replace_all, disable_backpressure: true) end)

      assert result == {3, nil}
      assert write.query["disable_backpressure"] == true
      assert {:ok, %{"billing" => %{"billable_logical_bytes_written" => _}}} = write.result
      assert ids(CardStack) == ~w(cs1 cs2 cs3)
    end
  end

  describe "update" do
    test "patches the changed fields" do
      stack = Repo.insert!(card_stack("a", markdown: "# Fractions"))

      Repo.update!(Ecto.Changeset.change(stack, title: "Decimals"))

      assert %CardStack{title: "Decimals", markdown: "# Fractions", vector: [1.0, +0.0, +0.0]} =
               Repo.get!(CardStack, "a")
    end

    test "can't patch vectors, ids, or text turbopuffer embeds, so those upsert instead" do
      stack = Repo.insert!(card_stack("a"))

      assert_raise ArgumentError, ~r/turbopuffer can't patch vectors/, fn ->
        Repo.update(Ecto.Changeset.change(stack, vector: [0.0, 1.0, 0.0]))
      end

      assert_raise ArgumentError, ~r/turbopuffer ids can't change/, fn ->
        Repo.update(Ecto.Changeset.change(stack, id: "b"))
      end

      lesson = Repo.insert!(%Lesson{markdown: "Mitosis splits one cell into two identical cells."})
      changeset = Ecto.Changeset.change(lesson, markdown: "Plants turn sunlight into sugar.")
      assert_raise ArgumentError, ~r/can't patch vectors or the text it embeds/, fn -> Repo.update(changeset) end

      Repo.insert!(Ecto.Changeset.apply_changes(changeset), on_conflict: :replace_all)
      assert Repo.get!(Lesson, lesson.id).markdown == "Plants turn sunlight into sugar."
    end

    test "raises when the document is gone, or an optimistic lock doesn't match" do
      stack = Repo.insert!(card_stack("a"))
      locked = fn changes -> stack |> Ecto.Changeset.change(changes) |> Ecto.Changeset.optimistic_lock(:position) end

      assert {:ok, %{position: 2}} = Repo.update(locked.(title: "Decimals"))
      assert Repo.get!(CardStack, "a").position == 2

      # The struct still says position 1, so the lock doesn't match.
      assert_raise Ecto.StaleEntryError, fn -> Repo.update(locked.(title: "Ratios")) end
      assert_raise Ecto.StaleEntryError, fn -> Repo.delete(Ecto.Changeset.optimistic_lock(stack, :position)) end
      assert Repo.get!(CardStack, "a").title == "Decimals"

      Repo.delete!(Repo.get!(CardStack, "a"))
      assert_raise Ecto.StaleEntryError, fn -> Repo.update(Ecto.Changeset.change(stack, title: "Gone")) end
    end
  end

  test "delete deletes a document, and raises when it's already gone" do
    stack = Repo.insert!(card_stack("a"))

    assert {:ok, _} = Repo.delete(stack)
    assert Repo.get(CardStack, "a") == nil
    assert_raise Ecto.StaleEntryError, fn -> Repo.delete(stack) end
    assert {:ok, _} = Repo.delete(stack, allow_stale: true)
  end

  describe "update_all and delete_all" do
    setup do
      rows =
        for {id, planbook} <- [a: "p1", b: "p1", c: "p2"] do
          %{id: "#{id}", title: "Stack", planbook_id: planbook, vector: [1.0, 0.0, 0.0]}
        end

      Repo.insert_all(CardStack, rows)
      :ok
    end

    test "patch and delete by filter" do
      assert Repo.update_all(from(c in CardStack, where: c.planbook_id == "p1"), set: [title: "Moved"]) == {2, nil}
      assert ids(from c in CardStack, where: c.title == "Moved") == ~w(a b)

      assert Repo.delete_all(from c in CardStack, where: c.planbook_id == "p1") == {2, nil}
      assert ids(CardStack) == ~w(c)

      assert Repo.delete_all(CardStack) == {1, nil}
      assert ids(CardStack) == []
    end

    test "a leading or_where only touches what it matches" do
      assert Repo.update_all(from(c in CardStack, or_where: c.id == "a"), set: [title: "Moved"]) == {1, nil}
      assert ids(from c in CardStack, where: c.title == "Moved") == ~w(a)

      assert Repo.delete_all(from c in CardStack, or_where: c.id == "c") == {1, nil}
      assert ids(CardStack) == ~w(a b)
    end

    test "update_all declares the schema, so an attribute it adds gets its type" do
      assert Repo.update_all(ReviewedCardStack, set: [reviewed_at: ~U[2026-01-01 00:00:00Z]]) == {3, nil}

      # A datetime turbopuffer had inferred as a string would make this insert fail, since types can't change.
      Repo.insert!(%ReviewedCardStack{id: "d", vector: [1.0, 0.0, 0.0], reviewed_at: ~U[2026-02-01 00:00:00Z]})

      assert ids(from r in ReviewedCardStack, where: r.reviewed_at > ^~U[2025-12-31 00:00:00Z]) == ~w(a b c d)
    end

    test "change nothing in a namespace that doesn't exist yet" do
      assert Repo.update_all(Everything, set: [title: "x"]) == {0, nil}
      assert Repo.delete_all(Everything) == {0, nil}
    end
  end
end
