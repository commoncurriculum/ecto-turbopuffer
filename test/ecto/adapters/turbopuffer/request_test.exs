defmodule Ecto.Adapters.Turbopuffer.RequestTest do
  use TP.Test.Case, async: true

  alias Ecto.Adapters.Turbopuffer.Request

  setup %{prefix: prefix} do
    {:ok, client: Ecto.Adapters.Turbopuffer.client(Repo), namespace: prefix <> "-request"}
  end

  test "writes, queries, lists, and deletes a namespace", context do
    %{client: client, namespace: namespace, prefix: prefix} = context

    assert {:ok, %{"rows_upserted" => 1}} = Request.write(client, namespace, %{upsert_rows: [%{id: "a", n: 1}]})

    assert {:ok, %{"rows" => [%{"id" => "a", "n" => 1}]}} =
             Request.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1, include_attributes: ["n"]})

    assert {:ok, %{"schema" => %{"n" => %{"type" => "int"}}}} = Request.metadata(client, namespace)
    assert Request.namespaces(client, prefix) == {:ok, [namespace]}

    assert {:ok, _} = Request.delete_namespace(client, namespace)
    assert Request.namespaces(client, prefix) == {:ok, []}
  end

  test "returns turbopuffer's errors as TP.Error", %{client: client, namespace: namespace} do
    assert {:error, %TP.Error{status: 404, message: message}} =
             Request.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1})

    assert message =~ "was not found"

    Request.write(client, namespace, %{upsert_rows: [%{id: "a"}]})

    assert {:error, %TP.Error{status: 400, message: message}} =
             Request.query(client, namespace, %{rank_by: ["id", "asc"], limit: 1, filters: ["nope", "Eq", 1]})

    assert message =~ "attribute not found"
  end

  test "returns connection errors as TP.Error" do
    client = Turbopuffer.Client.new(api_key: "key", base_url: "http://127.0.0.1:1", max_retries: 0)
    assert {:error, %TP.Error{status: nil, message: message}} = Request.metadata(client, "anything")
    assert message =~ "connection refused"
  end

  test "rejects invalid namespace names before sending", %{client: client} do
    assert_raise ArgumentError, ~r/must match \[A-Za-z0-9-_.\]\{1,128\}/, fn ->
      Request.query(client, "card stacks", %{})
    end
  end
end
