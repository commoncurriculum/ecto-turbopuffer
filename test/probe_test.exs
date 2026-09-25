defmodule TP.ProbeTest do
  # Temporary: which recall bodies turbopuffer takes. Removed once read.
  use TP.Test.Case, async: true

  alias Elixir.Turbopuffer.Client, as: Driver

  test "probe", %{prefix: prefix} do
    client = Turbopuffer.client(Repo)
    ns = "#{prefix}-rc"
    rows = for i <- 1..20, do: %{"id" => "s#{i}", "p" => "p1", "vector" => [i / 1, 1.0, 0.5]}

    {:ok, _} =
      Driver.post(client, "/v2/namespaces/#{ns}", %{
        "upsert_rows" => rows,
        "distance_metric" => "cosine_distance"
      })

    IO.puts("\n==PROBE==")

    for {label, body} <- [
          rank: %{"rank_by" => ["vector", "ANN", [3.0, 1.0, 0.5]], "top_k" => 3},
          rank_num1: %{"rank_by" => ["vector", "ANN", [3.0, 1.0, 0.5]], "top_k" => 3, "num" => 1},
          rank_filters: %{"rank_by" => ["vector", "ANN", [3.0, 1.0, 0.5]], "top_k" => 3, "filters" => ["p", "Eq", "p1"]},
          rank_filters_num1: %{
            "rank_by" => ["vector", "ANN", [3.0, 1.0, 0.5]],
            "top_k" => 3,
            "num" => 1,
            "filters" => ["p", "Eq", "p1"]
          },
          filters: %{"top_k" => 3, "filters" => ["p", "Eq", "p1"]},
          knn: %{"rank_by" => ["vector", "kNN", [3.0, 1.0, 0.5]], "top_k" => 3, "filters" => ["p", "Eq", "p1"]}
        ] do
      IO.puts("#{label}: #{inspect(Driver.post(client, "/v1/namespaces/#{ns}/_debug/recall", body))}")
    end

    IO.puts("==END PROBE==")
  end
end
