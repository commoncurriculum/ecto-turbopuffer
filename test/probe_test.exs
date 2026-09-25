defmodule TP.ProbeTest do
  # Temporary: asks turbopuffer which forms of Max it takes for signed attributes. Removed once read.
  use TP.Test.Case, async: true

  test "probe", %{prefix: prefix} do
    client = Ecto.Adapters.Turbopuffer.client(Repo)
    path = "/v2/namespaces/#{prefix}-rk"

    {:ok, _} =
      Turbopuffer.Client.post(client, path, %{
        "upsert_rows" => [
          %{"id" => "a", "delta" => -5, "ratio" => -0.5, "clicks" => 10, "at" => "2026-02-03T00:00:00Z", "t" => "fox"},
          %{
            "id" => "b",
            "delta" => 5,
            "ratio" => 0.5,
            "clicks" => 1000,
            "at" => "2026-01-01T00:00:00Z",
            "t" => "fox fox"
          }
        ],
        "schema" => %{
          "clicks" => "uint",
          "ratio" => "float",
          "at" => "datetime",
          "t" => %{"type" => "string", "full_text_search" => true}
        }
      })

    ranks = [
      max_list_const_first: ["Max", [0, ["Attribute", "delta"]]],
      max_list_const_last: ["Max", [["Attribute", "delta"], 0]],
      max_list_float: ["Max", [0.0, ["Attribute", "delta"]]],
      max_three: ["Max", ["Attribute", "delta"], 0],
      sum_const: ["Sum", [["Attribute", "clicks"], 5]],
      product_attr: ["Product", 2, ["Attribute", "clicks"]],
      product_attr_first: ["Product", ["Attribute", "clicks"], 2],
      saturate_signed: ["Saturate", ["Attribute", "delta"], %{"midpoint" => 2}],
      decay_signed: ["Decay", ["Attribute", "delta"], %{"midpoint" => 2}],
      saturate_float_signed: ["Saturate", ["Attribute", "ratio"], %{"midpoint" => 2}],
      attr_float: ["Attribute", "ratio"],
      attr_datetime: ["Attribute", "at"],
      dist_signed: ["Dist", ["Attribute", "delta"], 0],
      dist_float: ["Dist", ["Attribute", "ratio"], 0.25],
      saturate_bm25: ["Saturate", ["t", "BM25", "fox"], %{"midpoint" => 1}],
      product_filter_bm25: ["Sum", [["t", "BM25", "fox"], ["Product", 3, ["delta", "Gt", 0]]]],
      not_filter: ["Not", ["delta", "Gt", 0]],
      and_filter: ["And", [["delta", "Gt", 0], ["clicks", "Gt", 5]]],
      fuzzy_filter: ["t", "ContainsAnyToken", "fox"],
      max_two_attrs: ["Max", [["Attribute", "clicks"], ["Product", 100, ["Attribute", "clicks"]]]]
    ]

    IO.puts("\n==PROBE==")

    for {label, rank} <- ranks do
      result =
        Turbopuffer.Client.post(client, path <> "/query", %{
          "rank_by" => rank,
          "limit" => 2,
          "compute_attributes" => %{"c" => rank}
        })

      summary =
        case result do
          {:ok, %{"rows" => rows}} -> inspect(Enum.map(rows, &{&1["id"], &1["$dist"], &1["c"]}))
          other -> inspect(other)
        end

      IO.puts("#{label}: #{summary}")
    end

    IO.puts("==END PROBE==")
  end
end
