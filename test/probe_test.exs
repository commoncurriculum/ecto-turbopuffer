defmodule TP.ProbeTest do
  # Temporary: how turbopuffer answers vector arrays without an index or with f16 and i8, and the embedding shapes
  # it now accepts. Removed once read.
  use TP.Test.Case, async: true

  alias Elixir.Turbopuffer.Client, as: Driver

  @moduletag timeout: 600_000

  test "probe", %{prefix: prefix} do
    client = Turbopuffer.client(Repo)
    say = fn label, result -> IO.puts("#{label}: #{inspect(result, limit: :infinity, printable_limit: 2000)}") end
    q = [[0.0, 1.0], [0.2, 0.8]]

    rows = [
      %{"id" => "a", "p" => "p1", "tokens" => [[1.0, 0.0], [0.9, 0.1]]},
      %{"id" => "b", "p" => "p1", "tokens" => [[0.0, 1.0], [0.1, 0.9], [0.5, 0.5]]}
    ]

    IO.puts("\n==PROBE==")

    for {label, body} <- [
          no_ann: %{"schema" => %{"tokens" => %{"type" => "[][2]f32"}}},
          ann_false: %{"schema" => %{"tokens" => %{"type" => "[][2]f32", "ann" => false}}},
          ann_false_metric: %{
            "schema" => %{"tokens" => %{"type" => "[][2]f32", "ann" => false}},
            "distance_metric" => "cosine_distance"
          },
          f16: %{
            "schema" => %{"tokens" => %{"type" => "[][2]f16", "ann" => %{"late_interaction" => true}}},
            "distance_metric" => "cosine_distance"
          },
          i8: %{
            "schema" => %{"tokens" => %{"type" => "[][2]i8", "ann" => %{"late_interaction" => true}}},
            "distance_metric" => "cosine_distance"
          }
        ] do
      ns = "#{prefix}-#{label}"

      rows =
        if label == :i8,
          do: [%{"id" => "a", "tokens" => [[100, 0]]}, %{"id" => "b", "tokens" => [[0, 100]]}],
          else: rows

      say.("#{label} write", Driver.post(client, "/v2/namespaces/#{ns}", Map.put(body, "upsert_rows", rows)))
      say.("#{label} schema", with({:ok, m} <- Driver.get(client, "/v1/namespaces/#{ns}/metadata"), do: m["schema"]))

      for {kind, extra} <- [
            {"kNN", %{"filters" => ["id", "In", ["a", "b"]]}},
            {"ANN", %{}},
            {"ANN", %{"vector_encoding" => "base64"}}
          ] do
        body =
          Map.merge(%{"rank_by" => ["tokens", kind, q], "limit" => 2, "include_attributes" => ["tokens"]}, extra)

        say.("#{label} #{kind} #{inspect(extra)}", Driver.post(client, "/v2/namespaces/#{ns}/query", body))
      end
    end

    # qwen/qwen3-embedding-0p6b used to reject 7 dimensions and i8.
    for {dims, dtype} <- [{7, "f32"}, {256, "i8"}] do
      ns = "#{prefix}-qwen-#{dims}-#{dtype}"

      result =
        Driver.post(client, "/v2/namespaces/#{ns}", %{
          "upsert_rows" => [%{"id" => "a", "text" => "Fractions."}],
          "distance_metric" => "cosine_distance",
          "schema" => %{
            "text" => %{
              "type" => "string",
              "embed" => %{
                "model" => "qwen/qwen3-embedding-0p6b",
                "attribute" => "vector",
                "dims" => dims,
                "dtype" => dtype
              }
            },
            "vector" => %{"type" => "[#{dims}]#{dtype}", "ann" => true}
          }
        })

      say.("qwen #{dims} #{dtype}", result)
    end

    IO.puts("==END PROBE==")
  end
end
