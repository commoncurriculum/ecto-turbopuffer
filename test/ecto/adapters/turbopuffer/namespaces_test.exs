defmodule Ecto.Adapters.Turbopuffer.NamespacesTest do
  use TP.Test.Case, async: true

  alias TP.Test.{CardStack, Everything, ReviewedCardStack, ShardedStack}

  defp stacks(count, attrs \\ []) do
    for i <- 1..count do
      Map.merge(%{id: "s#{i}", title: "Stack #{i}", position: i, vector: [i / 1, 1.0, 0.5]}, Map.new(attrs))
    end
  end

  defp ids(queryable, opts \\ []), do: queryable |> Repo.all(opts) |> Enum.map(& &1.id) |> Enum.sort()

  test "metadata describes a namespace, which turbopuffer only has once it's written to", %{prefix: prefix} do
    error = assert_raise TP.Error, fn -> Turbopuffer.metadata(Repo, CardStack) end
    assert error.status == 404 and error.message =~ "#{prefix}-card_stacks"

    Repo.insert_all(CardStack, stacks(2))

    assert %{
             "schema" => %{"title" => %{"type" => "string"}, "vector" => %{"type" => "[3]f32"}},
             "approx_row_count" => rows,
             "approx_logical_bytes" => bytes,
             "created_at" => "20" <> _,
             "updated_at" => "20" <> _,
             "last_write_at" => "20" <> _,
             "encryption" => %{"sse" => true},
             "index" => %{"status" => status}
           } = Turbopuffer.metadata(Repo, CardStack)

    assert is_integer(rows) and is_integer(bytes) and status in ["up-to-date", "updating"]
  end

  test "pinning reserves compute for a namespace until it's unpinned" do
    Repo.insert_all(CardStack, stacks(1))

    assert %{"pinning" => %{"replicas" => 1}} = Turbopuffer.update_metadata(Repo, CardStack, pinning: [replicas: 1])
    assert %{"pinning" => %{"replicas" => 1}} = Turbopuffer.metadata(Repo, CardStack)
    refute Map.has_key?(Turbopuffer.update_metadata(Repo, CardStack, pinning: nil), "pinning")
  end

  test "read_only rejects writes until it's lifted" do
    Repo.insert_all(CardStack, stacks(1))

    assert %{"read_only" => true} = Turbopuffer.update_metadata(Repo, CardStack, read_only: true)
    assert_raise TP.Error, ~r/read-only/, fn -> Repo.insert!(%CardStack{id: "s2", vector: [1.0, 0.0, 0.0]}) end
    assert_raise TP.Error, ~r/read-only/, fn -> Repo.delete_all(CardStack) end
    assert ids(CardStack) == ~w(s1)

    refute Map.has_key?(Turbopuffer.update_metadata(Repo, CardStack, read_only: false), "read_only")
    Repo.insert!(%CardStack{id: "s2", vector: [1.0, 0.0, 0.0]})
    assert ids(CardStack) == ~w(s1 s2)
  end

  test "warm_cache hints that queries are coming" do
    assert_raise TP.Error, ~r/not found/, fn -> Turbopuffer.warm_cache(Repo, CardStack) end
    Repo.insert_all(CardStack, stacks(1))
    assert Turbopuffer.warm_cache(Repo, CardStack) == :ok
  end

  test "list_namespaces pages through the names with a prefix, and delete_namespace deletes one", %{prefix: prefix} do
    Repo.insert_all(CardStack, stacks(1))
    Repo.insert!(Everything.new(id: "e"))
    Repo.insert!(%ShardedStack{id: 1})
    names = Enum.map(~w(card_stacks everything sharded_stacks), &"#{prefix}-#{&1}")

    {listed, requests} = requests(fn -> Turbopuffer.list_namespaces(Repo, prefix: prefix <> "-", page_size: 2) end)
    assert Enum.sort(listed) == names
    assert length(requests) == 2

    assert Turbopuffer.delete_namespace(Repo, CardStack) == :ok
    assert Turbopuffer.list_namespaces(Repo, prefix: prefix <> "-") |> Enum.sort() == tl(names)
    assert Repo.all(CardStack) == []
    assert_raise TP.Error, ~r/not found/, fn -> Turbopuffer.delete_namespace(Repo, CardStack) end
  end

  test "branch makes an independent copy-on-write namespace", %{prefix: prefix} do
    Repo.insert_all(CardStack, stacks(2))
    source = Turbopuffer.namespace(CardStack, prefix)
    branch = prefix <> "-branch"

    assert Turbopuffer.branch(Repo, CardStack, from: source, prefix: branch) == :ok
    Repo.insert!(%CardStack{id: "s3", vector: [1.0, 0.0, 0.0]}, prefix: branch)
    Repo.delete_all(from(c in CardStack, where: c.id == "s1"))

    assert ids(CardStack, prefix: branch) == ~w(s1 s2 s3)
    assert ids(CardStack) == ~w(s2)
    assert %{"branching" => %{"parent" => ^source}} = Turbopuffer.metadata(Repo, CardStack, prefix: branch)
  end

  test "copy copies every document, from this region or another", %{prefix: prefix} do
    Repo.insert_all(CardStack, stacks(3))
    source = Turbopuffer.namespace(CardStack, prefix)

    assert Turbopuffer.copy(Repo, CardStack, from: source, prefix: prefix <> "-copy") == :ok
    assert ids(CardStack, prefix: prefix <> "-copy") == ~w(s1 s2 s3)

    assert Turbopuffer.copy(Repo, CardStack, from: source, from_region: "gcp-us-central1", prefix: prefix <> "-region") ==
             :ok

    assert ids(CardStack, prefix: prefix <> "-region") == ~w(s1 s2 s3)
    refute Map.has_key?(Turbopuffer.metadata(Repo, CardStack, prefix: prefix <> "-copy"), "branching")
  end

  test "update_schema declares the schema without writing documents" do
    Repo.insert_all(CardStack, stacks(1))
    assert Turbopuffer.update_schema(Repo, ReviewedCardStack) == :ok

    assert %{"reviewed_at" => %{"type" => "datetime"}, "title" => %{"type" => "string"}} =
             Turbopuffer.metadata(Repo, CardStack)["schema"]
  end

  test "num_shards partitions the namespace, and every operation works across the shards" do
    Repo.insert_all(ShardedStack, for(i <- 1..20, do: %{id: i, position: i}))
    assert %{"sharding" => %{"num_shards" => 2}} = Turbopuffer.metadata(Repo, ShardedStack)

    assert Repo.update_all(from(s in ShardedStack, where: s.position > 10), set: [position: 0]) == {10, nil}
    assert Repo.delete_all(from(s in ShardedStack, where: s.position == 0)) == {10, nil}
    Repo.update!(Ecto.Changeset.change(Repo.get!(ShardedStack, 1), position: 100))

    assert Repo.all(from s in ShardedStack, order_by: [desc: s.position], limit: 2, select: s.id) == [1, 10]
    assert Repo.aggregate(ShardedStack, :count) == 10
  end

  test "recall measures the vector index over random documents, with a query's filters and limit" do
    Repo.insert_all(CardStack, stacks(20, planbook_id: "p1"))

    assert %{"avg_recall" => recall, "avg_ann_count" => 5.0, "avg_exhaustive_count" => 5.0} =
             Turbopuffer.recall(Repo, CardStack, num: 3, top_k: 5)

    assert recall >= 0 and recall <= 1

    {result, [request]} =
      requests(fn -> Turbopuffer.recall(Repo, from(c in CardStack, where: c.planbook_id == "p1", limit: 3), num: 2) end)

    assert request.query == %{"filters" => ["planbook_id", "Eq", "p1"], "top_k" => 3, "num" => 2}
    assert %{"avg_recall" => _, "avg_ann_count" => 3.0, "avg_exhaustive_count" => 3.0} = result
  end
end
