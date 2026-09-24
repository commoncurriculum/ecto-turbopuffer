defmodule TP.ClientTest do
  use TP.Test.Case, async: true

  setup %{prefix: prefix} do
    {:ok, client: Ecto.Adapters.Turbopuffer.client(Repo), namespace: prefix <> "-client"}
  end

  test "writes, queries, lists, and deletes a namespace", %{client: client, namespace: namespace, prefix: prefix} do
    assert {:ok, %{"rows_upserted" => 1}} = TP.Client.write(client, namespace, %{upsert_rows: [%{id: "a", n: 1}]})

    assert {:ok, %{"rows" => [%{"id" => "a", "n" => 1}]}} =
             TP.Client.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1, include_attributes: ["n"]})

    assert {:ok, %{"schema" => %{"n" => %{"type" => "int"}}}} = TP.Client.metadata(client, namespace)
    assert TP.Client.namespaces(client, prefix: prefix) == {:ok, [namespace]}

    assert {:ok, _} = TP.Client.delete_namespace(client, namespace)
    assert TP.Client.namespaces(client, prefix: prefix) == {:ok, []}
  end

  test "returns turbopuffer's errors", %{client: client, namespace: namespace} do
    assert {:error, %TP.Error{status: 404, message: message}} =
             TP.Client.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1})

    assert message =~ "was not found"

    TP.Client.write(client, namespace, %{upsert_rows: [%{id: "a"}]})

    assert {:error, %TP.Error{status: 400, message: message}} =
             TP.Client.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1, filters: ["nope", "Eq", 1]})

    assert message =~ "attribute not found"
  end

  test "rejects invalid namespace names before sending", %{client: client} do
    assert_raise ArgumentError, ~r/must match \[A-Za-z0-9-_.\]\{1,128\}/, fn ->
      TP.Client.query(client, "card stacks", %{})
    end
  end

  test "needs an API key and a region" do
    assert_raise ArgumentError, ~r/needs an :api_key/, fn -> TP.Client.new(region: "gcp-us-central1") end
    assert_raise ArgumentError, ~r/needs a :region or :base_url/, fn -> TP.Client.new(api_key: "key") end
  end
end
