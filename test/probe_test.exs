defmodule TP.ProbeTest do
  # Temporary: how turbopuffer answers vector arrays and recall now they're enabled. Removed once read.
  use TP.Test.Case, async: true

  alias Elixir.Turbopuffer.Client, as: Driver

  @moduletag timeout: 600_000

  test "probe", %{prefix: prefix} do
    client = Turbopuffer.client(Repo)
    started = System.monotonic_time(:millisecond)

    say = fn label, result ->
      IO.puts(
        "[#{System.monotonic_time(:millisecond) - started}ms] #{label}: #{inspect(result, limit: :infinity, printable_limit: 2000)}"
      )
    end

    IO.puts("\n==PROBE==")

    li = "#{prefix}-li"

    rows = [
      %{"id" => "a", "p" => "p1", "vector" => [1.0, 0.0], "tokens" => [[1.0, 0.0], [0.9, 0.1]]},
      %{"id" => "b", "p" => "p1", "vector" => [0.0, 1.0], "tokens" => [[0.0, 1.0], [0.1, 0.9], [0.5, 0.5]]},
      %{"id" => "c", "p" => "p2", "vector" => [0.7, 0.7], "tokens" => [[0.7, 0.7]]}
    ]

    say.(
      :li_write,
      Driver.post(client, "/v2/namespaces/#{li}", %{
        "upsert_rows" => rows,
        "distance_metric" => "cosine_distance",
        "schema" => %{
          "vector" => %{"type" => "[2]f32", "ann" => true},
          "tokens" => %{"type" => "[][2]f32", "ann" => %{"late_interaction" => true}}
        }
      })
    )

    say.(:li_metadata, Driver.get(client, "/v1/namespaces/#{li}/metadata"))

    q = [[0.0, 1.0], [0.2, 0.8]]

    for {label, body} <- [
          ann: %{"rank_by" => ["tokens", "ANN", q], "limit" => 3, "include_attributes" => ["tokens"]},
          ann_b64: %{
            "rank_by" => ["tokens", "ANN", q],
            "limit" => 3,
            "include_attributes" => ["tokens", "vector"],
            "vector_encoding" => "base64"
          },
          ann_filter: %{"rank_by" => ["tokens", "ANN", q], "limit" => 3, "filters" => ["p", "Eq", "p1"]},
          ann_single: %{"rank_by" => ["tokens", "ANN", [0.0, 1.0]], "limit" => 3},
          knn: %{"rank_by" => ["tokens", "kNN", q], "limit" => 3, "filters" => ["p", "Eq", "p1"]},
          knn_nofilter: %{"rank_by" => ["tokens", "kNN", q], "limit" => 3},
          dist_select: %{
            "rank_by" => ["id", "asc"],
            "limit" => 3,
            "include_attributes" => ["id"],
            "filters" => ["id", "Eq", "a"]
          },
          vector_dist: %{
            "rank_by" => ["id", "asc"],
            "limit" => 3,
            "aggregate_by" => nil
          },
          select_vdist: %{
            "rank_by" => ["id", "asc"],
            "limit" => 3,
            "include_attributes" => %{"d" => ["VectorDist", "tokens", q]}
          },
          sum_ann_bm: %{
            "rank_by" => ["Sum", [["tokens", "ANN", q], ["vector", "ANN", [0.0, 1.0]]]],
            "limit" => 3
          },
          get_all: %{"rank_by" => ["id", "asc"], "limit" => 3, "include_attributes" => true}
        ] do
      say.(label, Driver.post(client, "/v2/namespaces/#{li}/query", Map.reject(body, fn {_, v} -> is_nil(v) end)))
    end

    say.(
      :li_patch,
      Driver.post(client, "/v2/namespaces/#{li}", %{"patch_rows" => [%{"id" => "a", "tokens" => [[0.5, 0.5]]}]})
    )

    say.(
      :li_upsert_wrongdims,
      Driver.post(client, "/v2/namespaces/#{li}", %{"upsert_rows" => [%{"id" => "d", "tokens" => [[0.5, 0.5, 0.1]]}]})
    )

    say.(
      :li_upsert_empty,
      Driver.post(client, "/v2/namespaces/#{li}", %{"upsert_rows" => [%{"id" => "e", "tokens" => []}]})
    )

    say.(
      :li_upsert_b64,
      Driver.post(client, "/v2/namespaces/#{li}", %{
        "upsert_rows" => [
          %{"id" => "f", "tokens" => [Base.encode64(<<1.0::float-32-little, 0.0::float-32-little>>)]}
        ]
      })
    )

    # ann: false stores the vectors without the index.
    plain = "#{prefix}-plain"

    say.(
      :plain_write,
      Driver.post(client, "/v2/namespaces/#{plain}", %{
        "upsert_rows" => Enum.map(rows, &Map.delete(&1, "vector")),
        "distance_metric" => "cosine_distance",
        "schema" => %{"tokens" => %{"type" => "[][2]f32", "ann" => false}}
      })
    )

    say.(:plain_metadata, Driver.get(client, "/v1/namespaces/#{plain}/metadata"))

    say.(
      :plain_knn,
      Driver.post(client, "/v2/namespaces/#{plain}/query", %{
        "rank_by" => ["tokens", "kNN", q],
        "limit" => 3,
        "filters" => ["p", "Eq", "p1"]
      })
    )

    say.(
      :plain_knn_nofilter,
      Driver.post(client, "/v2/namespaces/#{plain}/query", %{"rank_by" => ["tokens", "kNN", q], "limit" => 3})
    )

    say.(
      :plain_ann,
      Driver.post(client, "/v2/namespaces/#{plain}/query", %{"rank_by" => ["tokens", "ANN", q], "limit" => 3})
    )

    # f16 and no ann at all
    for {label, schema} <- [
          f16: %{"type" => "[][2]f16", "ann" => %{"late_interaction" => true}},
          i8: %{"type" => "[][2]i8", "ann" => %{"late_interaction" => true}},
          no_ann: %{"type" => "[][2]f32"},
          ann_true: %{"type" => "[][2]f32", "ann" => true},
          ann_li_false: %{"type" => "[][2]f32", "ann" => %{"late_interaction" => false}}
        ] do
      say.(
        label,
        Driver.post(client, "/v2/namespaces/#{prefix}-t-#{label}", %{
          "upsert_rows" => [%{"id" => "a", "tokens" => [[1.0, 0.0]]}],
          "distance_metric" => "cosine_distance",
          "schema" => %{"tokens" => schema}
        })
      )
    end

    # Recall, retrying 404s, on a fresh namespace.
    rc = "#{prefix}-rc"
    rc_rows = for i <- 1..20, do: %{"id" => "s#{i}", "p" => "p1", "vector" => [i / 1, 1.0, 0.5]}

    say.(
      :rc_write,
      Driver.post(client, "/v2/namespaces/#{rc}", %{"upsert_rows" => rc_rows, "distance_metric" => "cosine_distance"})
    )

    recall = fn ns, label, body ->
      result =
        Enum.reduce_while(1..40, nil, fn attempt, _ ->
          case Driver.post(client, "/v1/namespaces/#{ns}/_debug/recall", body) do
            {:error, {:http_error, 404, _}} = error ->
              if attempt < 40, do: Process.sleep(1_000)
              if attempt == 40, do: {:halt, {:gave_up, attempt, error}}, else: {:cont, nil}

            other ->
              {:halt, {attempt, other}}
          end
        end)

      say.(label, result)
    end

    v = [3.0, 1.0, 0.5]

    for {label, body} <- [
          plain: %{"top_k" => 3},
          rank_num1: %{"rank_by" => ["vector", "ANN", v], "top_k" => 3, "num" => 1},
          rank: %{"rank_by" => ["vector", "ANN", v], "top_k" => 3},
          rank_num2: %{"rank_by" => ["vector", "ANN", v], "top_k" => 3, "num" => 2},
          rank_filters_num1: %{
            "rank_by" => ["vector", "ANN", v],
            "top_k" => 3,
            "num" => 1,
            "filters" => ["p", "Eq", "p1"]
          },
          filters: %{"top_k" => 3, "filters" => ["p", "Eq", "p1"]},
          knn: %{"rank_by" => ["vector", "kNN", v], "top_k" => 3, "num" => 1},
          embed: %{"rank_by" => ["vector", "ANN", ["Embed", "hello"]], "top_k" => 3, "num" => 1},
          sum: %{"rank_by" => ["Sum", [["vector", "ANN", v]]], "top_k" => 3, "num" => 1}
        ] do
      recall.(rc, "recall_#{label}", body)
    end

    for {label, body} <- [
          plain: %{"top_k" => 2},
          rank_num1: %{"rank_by" => ["tokens", "ANN", q], "top_k" => 2, "num" => 1},
          vector_rank_num1: %{"rank_by" => ["vector", "ANN", [0.0, 1.0]], "top_k" => 2, "num" => 1}
        ] do
      recall.(li, "recall_li_#{label}", body)
    end

    # A namespace that doesn't exist, to see how long a 404 lasts (it should give up).
    say.(:recall_missing_once, Driver.post(client, "/v1/namespaces/#{prefix}-missing/_debug/recall", %{"top_k" => 3}))

    # A brand new namespace, recalled immediately with a rank_by and no wait.
    fresh = "#{prefix}-fresh"

    say.(
      :fresh_write,
      Driver.post(client, "/v2/namespaces/#{fresh}", %{"upsert_rows" => rc_rows, "distance_metric" => "cosine_distance"})
    )

    recall.(fresh, "recall_fresh_rank_num1", %{"rank_by" => ["vector", "ANN", v], "top_k" => 3, "num" => 1})

    fresh2 = "#{prefix}-fresh2"

    say.(
      :fresh2_write,
      Driver.post(client, "/v2/namespaces/#{fresh2}", %{
        "upsert_rows" => rc_rows,
        "distance_metric" => "cosine_distance"
      })
    )

    recall.(fresh2, "recall_fresh2_plain", %{"top_k" => 3})

    IO.puts("==END PROBE==")
  end
end
