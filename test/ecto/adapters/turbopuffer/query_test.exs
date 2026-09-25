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
      uuid = "769c134d-07b8-4225-954a-b6cc5ffc320c"

      Repo.insert!(Everything.new(id: "old", updated_at: ~U[2025-01-01 00:00:00Z], owner_uuid: uuid, is_public: true))
      Repo.insert!(Everything.new(id: "new", updated_at: ~U[2026-09-01 00:00:00Z], is_public: false))

      assert ids(from e in Everything, where: e.updated_at > ^~U[2026-01-01 00:00:00Z]) == ~w(new)
      assert ids(from e in Everything, where: e.owner_uuid == ^String.upcase(uuid)) == ~w(old)
      assert ids(from e in Everything, where: e.is_public == false) == ~w(new)
      assert ids(from e in Everything, order_by: [desc: e.updated_at], limit: 1) == ~w(new)
    end

    test "ordering comparisons never match nil, and != does, as in SQL" do
      Repo.insert!(%CardStack{id: "unpositioned", vector: [1.0, 0.0, 0.0]})

      assert ids(from c in CardStack, where: c.position < 3) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.position <= 2) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: not (c.position > 2)) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: not (c.position >= 3)) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: c.position > 3) == ~w(fractions)
      assert ids(from c in CardStack, where: c.position != 1) == ~w(cells fractions revolution unpositioned)
    end

    test "and, or, not, or_where, and constant filters" do
      query = from c in CardStack, where: c.planbook_id == "history" or (c.position == 1 and not (c.title == "Cells"))
      assert ids(query) == ~w(photosynthesis revolution)

      assert ids(from c in CardStack, where: c.planbook_id == "history", or_where: c.id == "fractions") ==
               ~w(fractions revolution)

      # A leading or_where has nothing to join, so it's the filter.
      assert ids(from c in CardStack, or_where: c.id == "cells") == ~w(cells)

      # not distributes over and; != matches nil, so fractions, with no planbook, is in.
      assert ids(from c in CardStack, where: not (c.planbook_id == "science" and c.position > 1)) ==
               ~w(fractions photosynthesis revolution)

      assert ids(from c in CardStack, where: ^dynamic([c], ^dynamic(true) and c.planbook_id == ^"science")) ==
               ~w(cells photosynthesis)

      assert ids(from c in CardStack, where: false) == []
      assert length(Repo.all(from c in CardStack, where: true)) == 4
    end

    test "arrays" do
      assert ids(from c in CardStack, where: contains(c.standard_ids, "LS1.C")) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: not contains(c.standard_ids, ^"LS1.C")) == ~w(fractions revolution)

      assert ids(from c in CardStack, where: contains_any(c.standard_ids, ^["LS1.B", "3.NF.A.1"])) ==
               ~w(cells fractions)

      assert ids(from c in CardStack, where: not contains_any(c.standard_ids, ^["LS1.B", "3.NF.A.1"])) ==
               ~w(photosynthesis revolution)

      assert ids(from c in CardStack, where: any_lt(c.standard_ids, "LS1.C")) == ~w(cells fractions)
      assert ids(from c in CardStack, where: any_lte(c.standard_ids, "3.NF.A.1")) == ~w(fractions)
      assert ids(from c in CardStack, where: any_gt(c.standard_ids, "LS1.B")) == ~w(cells photosynthesis)
      assert ids(from c in CardStack, where: any_gte(c.standard_ids, "LS1.C")) == ~w(cells photosynthesis)

      # Ecto only allows `value in field` on its own array types, so this takes a schemaless query.
      schemaless = fn where -> Repo.all(from(c in "card_stacks", select: c.id, order_by: c.id) |> where(^where)) end
      assert schemaless.(dynamic([c], "LS1.B" in c.standard_ids)) == ~w(cells)
      assert schemaless.(dynamic([c], "LS1.C" not in c.standard_ids)) == ~w(fractions revolution)
    end

    test "like, ilike and globs, with glob's own metacharacters matching literally" do
      Repo.insert!(%CardStack{id: "odd", title: "100% [draft]? {x}*", vector: [1.0, 0.0, 0.0]})

      assert ids(from c in CardStack, where: like(c.title, "Photo%")) == ~w(photosynthesis)
      assert ids(from c in CardStack, where: ilike(c.title, ^"%REVOLUTION")) == ~w(revolution)
      assert ids(from c in CardStack, where: like(c.title, "Fraction_")) == ~w(fractions)
      assert ids(from c in CardStack, where: not like(c.title, "%i%")) == ~w(odd)
      assert ids(from c in CardStack, where: like(c.title, "100\\% [draft]? {x}*")) == ~w(odd)
      assert ids(from c in CardStack, where: like(c.id, "photo%")) == ~w(photosynthesis)
      assert ids(from c in CardStack, where: glob(c.title, "*Revolution")) == ~w(revolution)
      assert ids(from c in CardStack, where: iglob(c.title, "the french*")) == ~w(revolution)
      assert ids(from c in CardStack, where: not iglob(c.title, "*o*")) == ~w(odd)
    end

    test "regex" do
      Repo.insert!(Everything.new(id: "a", title: "Photosynthesis in plants"))
      Repo.insert!(Everything.new(id: "b", title: "Cell division"))

      assert ids(from e in Everything, where: regex(e.title, "^Photo.*plants$")) == ~w(a)
      assert ids(from e in Everything, where: not regex(e.title, "^Photo")) == ~w(b)
    end

    test "fuzzy and token filters" do
      assert ids(from c in CardStack, where: fuzzy(c.title, ^"fotosynthesis")) == ~w(photosynthesis)

      strict = %{max_edit_distance: [%{min_query_chars: 3, distance: 0}]}
      assert ids(from c in CardStack, where: fuzzy(c.title, ^"fotosynthesis", ^strict)) == []

      lenient = %{max_edit_distance: [%{min_query_chars: 3, distance: 0}], case_sensitive: false}
      assert ids(from c in CardStack, where: fuzzy(c.title, ^"PHOTOSYNTHESIS", ^lenient)) == ~w(photosynthesis)

      assert ids(from c in CardStack, where: contains_all_tokens(c.markdown, ^"sugar plants")) == ~w(photosynthesis)

      assert ids(from c in CardStack, where: contains_any_token(c.markdown, ^"mitosis bastille")) ==
               ~w(cells revolution)

      assert ids(from c in CardStack, where: contains_token_sequence(c.markdown, ^"one cell into two")) == ~w(cells)
      assert ids(from c in CardStack, where: contains_token_sequence(c.markdown, ^"two into cell")) == []
    end
  end

  describe "ordering, limits and paging" do
    test "by fields, with an offset" do
      assert ids(from c in CardStack, order_by: [desc: c.position], limit: 10) ==
               ~w(fractions revolution cells photosynthesis)

      assert ids(from c in CardStack, order_by: [c.planbook_id, desc: c.position], limit: 3) ==
               ~w(fractions revolution cells)

      assert ids(from c in CardStack, order_by: c.position, limit: 2, offset: 1) == ~w(cells revolution)
    end

    test "limit_per caps the rows sharing values of some fields" do
      query = from c in CardStack, order_by: [desc: c.position], limit: 10
      assert Repo.all(query, limit_per: {[:planbook_id], 1}) |> Enum.map(& &1.id) == ~w(fractions revolution cells)
      assert Repo.all(query, limit_per: {[:planbook_id, :position], 1}) |> length() == 4
    end

    test "a query ordered by id without a limit reads every page, each filtered past the last one's final id" do
      rows =
        for i <- 1..10_001,
            do: %{id: "p" <> String.pad_leading("#{i}", 5, "0"), position: 100 + i, vector: [1.0, 0.0, 0.0]}

      {_, writes} = requests(fn -> Repo.insert_all(CardStack, rows) end)
      assert Enum.map(writes, &length(&1.query["upsert_rows"])) == List.duplicate(1_000, 10) ++ [1]

      {read, queries} = requests(fn -> ids(from c in CardStack, where: c.position > 100, order_by: [desc: c.id]) end)
      assert read == rows |> Enum.map(& &1.id) |> Enum.reverse()

      assert Enum.map(queries, & &1.query["filters"]) == [
               ["position", "Gt", 100],
               ["And", [["position", "Gt", 100], ["id", "Lt", "p00002"]]]
             ]

      assert Enum.count(Repo.stream(CardStack)) == 10_005
    end
  end

  describe "selects and aggregates" do
    test "fields, maps, and literals" do
      assert Repo.all(from c in CardStack, where: c.id == "fractions", select: {c.id, c.title, c.position, "lit"}) ==
               [{"fractions", "Fractions", 4, "lit"}]

      assert Repo.one(from c in CardStack, where: c.id == "fractions", select: %{title: c.title}) == %{
               title: "Fractions"
             }

      assert Repo.all(from c in "card_stacks", where: c.planbook_id == "history", select: {c.id, c.position}) ==
               [{"revolution", 3}]
    end

    test "count, sum, group_by, and exists?" do
      assert Repo.aggregate(CardStack, :count) == 4
      assert Repo.aggregate(from(c in CardStack, where: c.planbook_id == "science"), :count, :id) == 2
      assert Repo.aggregate(CardStack, :sum, :position) == 10

      query = from c in CardStack, group_by: c.planbook_id, select: {c.planbook_id, count(), sum(c.position)}, limit: 10
      assert Enum.sort(Repo.all(query)) == [{nil, 1, 4}, {"history", 1, 3}, {"science", 2, 3}]

      assert Repo.exists?(from c in CardStack, where: c.planbook_id == "history")
      refute Repo.exists?(from c in CardStack, where: c.planbook_id == "art")
    end

    test "a namespace that doesn't exist yet reads as empty" do
      assert Repo.all(Everything) == []
      assert Repo.get(Everything, "doc") == nil
      assert Repo.aggregate(Everything, :count) == 0
      assert Repo.aggregate(Everything, :sum, :position) == nil
    end

    test "filters compare against any value, like an id too long to write" do
      assert Repo.get(CardStack, String.duplicate("a", 65)) == nil
    end
  end

  test "consistency: :eventual" do
    {rows, [request]} = requests(fn -> Repo.all(CardStack, consistency: :eventual) end)
    assert request.query["consistency"] == %{"level" => "eventual"}

    assert rows
           |> Enum.map(& &1.id)
           |> MapSet.new()
           |> MapSet.subset?(MapSet.new(~w(cells fractions photosynthesis revolution)))
  end

  test "telemetry reports each request with turbopuffer's billing and performance figures" do
    {_, [request]} = requests(fn -> Repo.all(from c in CardStack, where: c.id == "cells") end)

    assert %{kind: :query, source: "ecto-tpuf-test-" <> _, repo: Repo, query: %{"filters" => ["id", "Eq", "cells"]}} =
             request

    assert {:ok, %{"billing" => %{"billable_logical_bytes_queried" => _}, "performance" => %{"server_total_ms" => _}}} =
             request.result
  end

  test "turbopuffer's errors raise TP.Error" do
    error = assert_raise TP.Error, fn -> Repo.all(from c in "card_stacks", where: c.nope == 1, select: c.id) end
    assert error.status == 400
    assert error.message =~ "attribute not found"
  end
end
