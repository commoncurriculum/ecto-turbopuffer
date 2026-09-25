defmodule TP.ProbeTest do
  # Temporary: asks turbopuffer which embedding shapes each model accepts. Removed once read.
  use TP.Test.Case, async: true

  @models ~w(
    baai/bge-m3 cohere/embed-v4.0 google/gemini-embedding-2 nvidia/nemotron-3-embed-1b nvidia/nemotron-3-embed-8b
    openai/text-embedding-3-large openai/text-embedding-3-small openai/text-embedding-ada-002 qwen/qwen3-embedding-0p6b
    qwen/qwen3-embedding-4b qwen/qwen3-embedding-8b voyage/voyage-4 voyage/voyage-4-large voyage/voyage-4-lite
    voyage/voyage-4-nano voyage/voyage-code-3 voyage/voyage-code-4 zeroentropy/zembed-1
  )

  @variants [
    default: nil,
    dims7: %{"dims" => 7},
    dims256: %{"dims" => 256},
    f16: %{"dtype" => "f16"},
    i8: %{"dtype" => "i8"},
    u8: %{"dtype" => "u8"}
  ]

  @tag timeout: 600_000
  test "probe", %{prefix: prefix} do
    client = Ecto.Adapters.Turbopuffer.client(Repo)

    cases = for {model, i} <- Enum.with_index(@models), {variant, extra} <- @variants, do: {model, i, variant, extra}

    lines =
      cases
      |> Task.async_stream(&probe(client, prefix, &1), max_concurrency: 12, timeout: 120_000, ordered: true)
      |> Enum.map(fn {:ok, line} -> line end)

    extra =
      [
        late_interaction(client, prefix),
        highlight(client, prefix),
        recall(client, prefix)
      ]

    IO.puts("\n==PROBE==\n" <> Enum.join(lines ++ extra, "\n") <> "\n==END PROBE==")
  end

  defp probe(client, prefix, {model, i, variant, extra}) do
    ns = "#{prefix}-p#{i}-#{variant}"
    embed = if extra, do: Map.put(extra, "model", model), else: model

    body = %{
      "upsert_rows" => [
        %{"id" => "a", "text" => "Plants turn sunlight into sugar through photosynthesis."},
        %{"id" => "b", "text" => "The storming of the Bastille began the French Revolution."}
      ],
      "distance_metric" => "cosine_distance",
      "schema" => %{"text" => %{"type" => "string", "embed" => embed}}
    }

    case Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}", body) do
      {:ok, _} ->
        {:ok, meta} = Turbopuffer.Client.get(client, "/v1/namespaces/#{ns}/metadata")

        query = %{
          "rank_by" => ["text", "ANN", ["Embed", "how do leaves make food?"]],
          "limit" => 2,
          "include_attributes" => ["embed_text"]
        }

        top =
          case Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}/query", query) do
            {:ok, %{"rows" => [row | _]}} ->
              v = row["embed_text"]
              "top=#{row["id"]} dist=#{row["$dist"]} vec=#{inspect(v && Enum.take(v, 3))} len=#{v && length(v)}"

            other ->
              "query_error=#{inspect(other)}"
          end

        "#{model} #{variant} OK schema=#{inspect(meta["schema"])} #{top}"

      {:error, error} ->
        "#{model} #{variant} ERROR #{inspect(error)}"
    end
  end

  defp late_interaction(client, prefix) do
    ns = "#{prefix}-li"

    body = %{
      "upsert_rows" => [
        %{"id" => "a", "tokens" => [[1.0, 0.0], [0.0, 1.0]]},
        %{"id" => "b", "tokens" => [[0.5, 0.5]]}
      ],
      "distance_metric" => "cosine_distance",
      "schema" => %{"tokens" => %{"type" => "[][2]f32", "ann" => %{"late_interaction" => true}}}
    }

    write = Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}", body)

    query =
      Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}/query", %{
        "rank_by" => ["tokens", "ANN", [[1.0, 0.0]]],
        "limit" => 2,
        "include_attributes" => ["tokens"],
        "vector_encoding" => "base64"
      })

    "late_interaction write=#{inspect(write)} query=#{inspect(query)}"
  end

  defp highlight(client, prefix) do
    ns = "#{prefix}-hl"

    body = %{
      "upsert_rows" => [
        %{"id" => "a", "text" => "The quick brown fox jumps. Then it sleeps in the sun. Foxes are clever."}
      ],
      "schema" => %{"text" => %{"type" => "string", "full_text_search" => true}}
    }

    write = Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}", body)

    query =
      Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}/query", %{
        "rank_by" => ["text", "BM25", "fox"],
        "limit" => 1,
        "compute_attributes" => %{
          "hl" => ["Highlight", "text", %{"include_offsets" => "codepoints"}],
          "score" => ["text", "BM25", "fox"]
        }
      })

    "highlight write=#{inspect(write)} query=#{inspect(query)}"
  end

  defp recall(client, prefix) do
    ns = "#{prefix}-rc"
    rows = for i <- 1..20, do: %{"id" => i, "vector" => [i / 1, 1.0, 0.5]}

    write =
      Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}", %{
        "upsert_rows" => rows,
        "distance_metric" => "euclidean_squared"
      })

    recall = Turbopuffer.Client.post(client, "/v1/namespaces/#{ns}/_debug/recall", %{"num" => 3, "top_k" => 5})
    warm = Turbopuffer.Client.get(client, "/v1/namespaces/#{ns}/hint_cache_warm")

    ro =
      Turbopuffer.Client.request(client, :patch, "/v1/namespaces/#{ns}/metadata", %{"read_only" => true})

    ro_write =
      Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}", %{
        "upsert_rows" => [%{"id" => 99, "vector" => [1.0, 1.0, 1.0]}]
      })

    branch =
      Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}-br", %{"branch_from_namespace" => ns})

    copy = Turbopuffer.Client.post(client, "/v2/namespaces/#{ns}-cp", %{"copy_from_namespace" => ns})
    meta = Turbopuffer.Client.get(client, "/v1/namespaces/#{ns}-br/metadata")
    unro = Turbopuffer.Client.request(client, :patch, "/v1/namespaces/#{ns}/metadata", %{"read_only" => false})

    "recall write=#{inspect(write)}\nrecall=#{inspect(recall)}\nwarm=#{inspect(warm)}\nread_only=#{inspect(ro)}\n" <>
      "ro_write=#{inspect(ro_write)}\nbranch=#{inspect(branch)}\ncopy=#{inspect(copy)}\nbranch_meta=#{inspect(meta)}\n" <>
      "unro=#{inspect(unro)}"
  end
end
