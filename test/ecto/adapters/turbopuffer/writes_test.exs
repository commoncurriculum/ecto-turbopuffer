defmodule Ecto.Adapters.Turbopuffer.WritesTest do
  use TP.Test.Case, async: true

  alias TP.Test.{CardStack, Lesson}

  defp card_stack(id, attrs \\ []) do
    struct(%CardStack{id: id, title: "Fractions", position: 1, vector: [1.0, 0.0, 0.0]}, attrs)
  end

  defp ids(queryable), do: queryable |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  describe "insert" do
    test "writes a document" do
      assert {:ok, _} = Repo.insert(card_stack("a", markdown: "# Fractions"))
      assert %CardStack{title: "Fractions", markdown: "# Fractions"} = Repo.get!(CardStack, "a")
    end

    test "won't overwrite an existing id by default" do
      Repo.insert!(card_stack("a"))

      changeset = card_stack("a", title: "Decimals") |> Ecto.Changeset.change() |> Ecto.Changeset.unique_constraint(:id)
      assert {:error, changeset} = Repo.insert(changeset)
      assert {"has already been taken", _} = changeset.errors[:id]

      assert_raise Ecto.ConstraintError, ~r/"card_stacks_id_index" \(unique_constraint\)/, fn ->
        Repo.insert(card_stack("a", title: "Decimals"))
      end

      assert Repo.get!(CardStack, "a").title == "Fractions"
    end

    test "on_conflict: :nothing skips an existing id and :replace_all overwrites it" do
      Repo.insert!(card_stack("a"))

      Repo.insert!(card_stack("a", title: "Decimals"), on_conflict: :nothing)
      assert Repo.get!(CardStack, "a").title == "Fractions"

      Repo.insert!(card_stack("a", title: "Decimals"), on_conflict: :replace_all)
      assert Repo.get!(CardStack, "a").title == "Decimals"
    end

    test "refuses to replace only some fields" do
      assert_raise ArgumentError, ~r/must replace every field/, fn ->
        Repo.insert(card_stack("a"), on_conflict: {:replace, [:title]})
      end
    end

    test "needs every vector" do
      assert_raise ArgumentError, ~r/without :vector: turbopuffer upserts must include every vector/, fn ->
        Repo.insert(card_stack("a", vector: nil))
      end
    end

    test "autogenerates uuid ids and lets native embedding fill vectors" do
      lessons =
        for markdown <- [
              "Plants turn sunlight into sugar through photosynthesis.",
              "The storming of the Bastille began the French Revolution.",
              "Mitosis splits one cell into two identical cells."
            ] do
          Repo.insert!(%Lesson{markdown: markdown})
        end

      assert Enum.all?(lessons, &match?({:ok, _}, Ecto.UUID.cast(&1.id)))

      [first | _] =
        Repo.all(from l in Lesson, order_by: ann(l.markdown, embed(^"how do leaves make food?")), limit: 3)

      assert first.markdown =~ "photosynthesis"
    end
  end

  describe "insert_all" do
    test "writes documents in batches" do
      rows = for i <- 1..5, do: %{id: "cs#{i}", title: "Stack #{i}", position: i, vector: [1.0, 0.0, 0.0]}

      assert Repo.insert_all(CardStack, rows, batch_size: 2) == {5, nil}
      assert ids(CardStack) == ~w(cs1 cs2 cs3 cs4 cs5)
    end

    test "resolves placeholders" do
      rows = [%{id: "a", title: {:placeholder, :title}, vector: [1.0, 0.0, 0.0]}]
      assert Repo.insert_all(CardStack, rows, placeholders: %{title: "Shared"}) == {1, nil}
      assert Repo.get!(CardStack, "a").title == "Shared"
    end

    test "handles existing ids by on_conflict" do
      rows = [%{id: "a", title: "One", vector: [1.0, 0.0, 0.0]}, %{id: "b", title: "Two", vector: [1.0, 0.0, 0.0]}]
      Repo.insert_all(CardStack, Enum.take(rows, 1))

      assert_raise ArgumentError, ~r/1 of 2 ids already exist in ecto-tpuf-test-\w+-card_stacks/, fn ->
        Repo.insert_all(CardStack, rows)
      end

      assert Repo.insert_all(CardStack, rows, on_conflict: :nothing) == {0, nil}

      renamed = Enum.map(rows, &%{&1 | title: "Renamed"})
      assert Repo.insert_all(CardStack, renamed, on_conflict: :replace_all) == {2, nil}
      assert Enum.map(Repo.all(CardStack), & &1.title) == ["Renamed", "Renamed"]
    end
  end

  describe "update" do
    test "patches the changed fields" do
      stack = Repo.insert!(card_stack("a", markdown: "# Fractions"))

      Repo.update!(Ecto.Changeset.change(stack, title: "Decimals"))

      assert %CardStack{title: "Decimals", markdown: "# Fractions", vector: [1.0, +0.0, +0.0]} =
               Repo.get!(CardStack, "a")
    end

    test "can't patch text that turbopuffer embeds natively" do
      lesson = Repo.insert!(%Lesson{markdown: "Mitosis splits one cell into two identical cells."})
      changeset = Ecto.Changeset.change(lesson, markdown: "Plants turn sunlight into sugar.")

      assert_raise ArgumentError, ~r/can't patch vectors or the text it embeds/, fn -> Repo.update(changeset) end

      assert_raise Ecto.QueryError, ~r/can't patch vectors or the text it embeds/, fn ->
        Repo.update_all(Lesson, set: [markdown: "Plants"])
      end

      Repo.insert!(Ecto.Changeset.apply_changes(changeset), on_conflict: :replace_all)
      assert Repo.get!(Lesson, lesson.id).markdown == "Plants turn sunlight into sugar."
    end

    test "can't patch vectors" do
      stack = Repo.insert!(card_stack("a"))

      assert_raise ArgumentError, ~r/turbopuffer can't patch vectors/, fn ->
        Repo.update(Ecto.Changeset.change(stack, vector: [0.0, 1.0, 0.0]))
      end
    end

    test "raises on a document that's gone" do
      stack = Repo.insert!(card_stack("a"))
      Repo.delete!(stack)

      assert_raise Ecto.StaleEntryError, fn -> Repo.update(Ecto.Changeset.change(stack, title: "Decimals")) end
    end
  end

  describe "delete" do
    test "deletes a document and raises when it's already gone" do
      stack = Repo.insert!(card_stack("a"))

      assert {:ok, _} = Repo.delete(stack)
      assert Repo.get(CardStack, "a") == nil
      assert_raise Ecto.StaleEntryError, fn -> Repo.delete(stack) end
      assert {:ok, _} = Repo.delete(stack, allow_stale: true)
    end
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

    test "can't patch vectors by filter" do
      assert_raise Ecto.QueryError, ~r/can't patch vectors/, fn ->
        Repo.update_all(CardStack, set: [vector: [0.0, 1.0, 0.0]])
      end
    end
  end
end
