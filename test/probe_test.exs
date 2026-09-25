defmodule TP.ProbeTest do
  # Temporary: asks turbopuffer how it handles request shapes the docs leave open. Removed once read.
  use TP.Test.Case, async: true

  @tag timeout: 600_000
  test "probe", %{prefix: prefix} do
    client = Ecto.Adapters.Turbopuffer.client(Repo)
    post = fn path, body -> Turbopuffer.Client.post(client, path, body) end
    get = fn path -> Turbopuffer.Client.get(client, path) end
    ns = fn name -> "/v2/namespaces/#{prefix}-#{name}" end

    results = [
      # Sharding on the first write, then again on a later write, then a different count.
      shard1:
        post.(ns.("sh"), %{
          "upsert_rows" => [%{"id" => "a", "n" => 1}],
          "sharding" => %{"num_shards" => 2}
        }),
      shard2: post.(ns.("sh"), %{"upsert_rows" => [%{"id" => "b", "n" => 2}], "sharding" => %{"num_shards" => 2}}),
      shard3: post.(ns.("sh"), %{"upsert_rows" => [%{"id" => "c", "n" => 3}], "sharding" => %{"num_shards" => 4}}),
      shard_meta: get.("/v1/namespaces/#{prefix}-sh/metadata"),
      shard_query: post.(ns.("sh") <> "/query", %{"rank_by" => ["id", "asc"], "limit" => 10}),
      backpressure: post.(ns.("bp"), %{"upsert_rows" => [%{"id" => "a", "n" => 1}], "disable_backpressure" => true}),
      # Conditional upsert with $ref_new: only replace when the new updated_at is later.
      cond0:
        post.(ns.("cu"), %{
          "upsert_rows" => [%{"id" => "a", "v" => 1, "at" => "2026-01-02T00:00:00Z"}],
          "schema" => %{"at" => "datetime"}
        }),
      cond_old:
        post.(ns.("cu"), %{
          "upsert_rows" => [
            %{"id" => "a", "v" => 2, "at" => "2026-01-01T00:00:00Z"},
            %{"id" => "b", "v" => 9, "at" => "2026-01-01T00:00:00Z"}
          ],
          "upsert_condition" => ["at", "Lt", %{"$ref_new" => "at"}],
          "return_affected_ids" => true
        }),
      cond_new:
        post.(ns.("cu"), %{
          "upsert_rows" => [%{"id" => "a", "v" => 3, "at" => "2026-01-03T00:00:00Z"}],
          "upsert_condition" => ["at", "Lt", %{"$ref_new" => "at"}],
          "return_affected_ids" => true
        }),
      cond_patch:
        post.(ns.("cu"), %{
          "patch_rows" => [%{"id" => "a", "v" => 4, "at" => "2026-01-02T00:00:00Z"}],
          "patch_condition" => ["at", "Lt", %{"$ref_new" => "at"}],
          "return_affected_ids" => true
        }),
      cond_rows:
        post.(ns.("cu") <> "/query", %{"rank_by" => ["id", "asc"], "limit" => 10, "include_attributes" => true}),
      # Ranking expressions.
      rank0:
        post.(ns.("rk"), %{
          "upsert_rows" => [
            %{
              "id" => "a",
              "title" => "quick fox",
              "clicks" => 10,
              "delta" => -5,
              "species" => "whale",
              "at" => "2026-02-03T00:00:00Z"
            },
            %{
              "id" => "b",
              "title" => "quick fox",
              "clicks" => 1000,
              "delta" => 5,
              "species" => "fox",
              "at" => "2026-01-01T00:00:00Z"
            }
          ],
          "schema" => %{
            "title" => %{"type" => "string", "full_text_search" => true},
            "at" => "datetime",
            "clicks" => "uint"
          }
        }),
      rank_filter:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Sum", [["title", "BM25", "fox"], ["species", "Eq", "whale"]]],
          "limit" => 2
        }),
      rank_filter_product:
        post.(ns.("rk") <> "/query", %{"rank_by" => ["Product", 2.0, ["species", "Eq", "whale"]], "limit" => 2}),
      rank_filter_alone: post.(ns.("rk") <> "/query", %{"rank_by" => ["species", "Eq", "whale"], "limit" => 2}),
      rank_attr_uint: post.(ns.("rk") <> "/query", %{"rank_by" => ["Attribute", "clicks"], "limit" => 2}),
      rank_attr_int: post.(ns.("rk") <> "/query", %{"rank_by" => ["Attribute", "delta"], "limit" => 2}),
      rank_max_int: post.(ns.("rk") <> "/query", %{"rank_by" => ["Max", 0, ["Attribute", "delta"]], "limit" => 2}),
      rank_max_list:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Max", [["title", "BM25", "fox"], ["Attribute", "clicks"]]],
          "limit" => 2
        }),
      rank_saturate:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Saturate", ["Attribute", "clicks"], %{"midpoint" => 100}],
          "limit" => 2
        }),
      rank_saturate_exp:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Saturate", ["Attribute", "clicks"], %{"midpoint" => 100, "exponent" => 2}],
          "limit" => 2
        }),
      rank_decay:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Decay", ["Attribute", "clicks"], %{"midpoint" => 100}],
          "limit" => 2
        }),
      rank_dist_datetime:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Decay", ["Dist", ["Attribute", "at"], "2026-02-03T00:00:00Z"], %{"midpoint" => "6h"}],
          "limit" => 2
        }),
      rank_dist_ms:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Decay", ["Dist", ["Attribute", "at"], "2026-02-03T00:00:00Z"], %{"midpoint" => 21_600_000}],
          "limit" => 2
        }),
      rank_dist_number:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Decay", ["Dist", ["Attribute", "clicks"], 10], %{"midpoint" => 5}],
          "limit" => 2
        }),
      rank_dist_alone:
        post.(ns.("rk") <> "/query", %{"rank_by" => ["Dist", ["Attribute", "clicks"], 10], "limit" => 2}),
      rank_sum_score_select:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["Sum", [["title", "BM25", "fox"], ["Saturate", ["Attribute", "clicks"], %{"midpoint" => 100}]]],
          "limit" => 2,
          "compute_attributes" => %{
            "sat" => ["Saturate", ["Attribute", "clicks"], %{"midpoint" => 100}],
            "f" => ["species", "Eq", "whale"]
          }
        }),
      rank_attr_desc: post.(ns.("rk") <> "/query", %{"rank_by" => ["clicks", "desc"], "limit" => 2}),
      highlight_no_bm25:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 2,
          "compute_attributes" => %{"hl" => ["Highlight", "title"]}
        }),
      highlight_rank_fragments:
        post.(ns.("rk") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 2,
          "compute_attributes" => %{
            "hl" => [
              "Highlight",
              "title",
              %{"rank_fragments_by" => ["$fragment", "BM25", "fox"], "fragment_by" => "word", "fragment_limit" => 1}
            ]
          }
        }),
      # Pre-tokenized BM25 takes []string query operands.
      pretok0:
        post.(ns.("pt"), %{
          "upsert_rows" => [
            %{"id" => "a", "toks" => ["self-evident", "truth"]},
            %{"id" => "b", "toks" => ["self", "evident"]}
          ],
          "schema" => %{
            "toks" => %{"type" => "[]string", "full_text_search" => %{"tokenizer" => "pre_tokenized_array"}}
          }
        }),
      pretok_bm25: post.(ns.("pt") <> "/query", %{"rank_by" => ["toks", "BM25", ["self-evident"]], "limit" => 2}),
      pretok_all:
        post.(ns.("pt") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "filters" => ["toks", "ContainsAllTokens", ["self", "evident"]],
          "limit" => 2
        }),
      pretok_string: post.(ns.("pt") <> "/query", %{"rank_by" => ["toks", "BM25", "self"], "limit" => 2}),
      # Vector encodings for each element type.
      enc0:
        post.(ns.("en"), %{
          "upsert_rows" => [%{"id" => "a", "f" => [0.5, -1.25], "h" => [0.5, -1.25], "q" => [-128, 127]}],
          "distance_metric" => "cosine_distance",
          "schema" => %{
            "f" => %{"type" => "[2]f32", "ann" => true},
            "h" => %{"type" => "[2]f16", "ann" => true},
            "q" => %{"type" => "[2]i8", "ann" => true}
          }
        }),
      enc_base64:
        post.(ns.("en") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 1,
          "include_attributes" => ["f", "h", "q"],
          "vector_encoding" => "base64"
        }),
      enc_float:
        post.(ns.("en") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 1,
          "include_attributes" => ["f", "h", "q"]
        }),
      # Multi-vectors without the late-interaction index.
      mv0:
        post.(ns.("mv"), %{
          "upsert_rows" => [
            %{"id" => "a", "cat" => "x", "tokens" => [[1.0, 0.0], [0.0, 1.0]]},
            %{"id" => "b", "cat" => "x", "tokens" => [[0.5, 0.5]]}
          ],
          "distance_metric" => "cosine_distance",
          "schema" => %{"tokens" => %{"type" => "[][2]f32", "ann" => false}}
        }),
      mv_knn:
        post.(ns.("mv") <> "/query", %{
          "rank_by" => ["tokens", "kNN", [[1.0, 0.0]]],
          "filters" => ["cat", "Eq", "x"],
          "limit" => 2,
          "include_attributes" => ["tokens"]
        }),
      mv_knn_b64:
        post.(ns.("mv") <> "/query", %{
          "rank_by" => ["tokens", "kNN", [[1.0, 0.0]]],
          "filters" => ["cat", "Eq", "x"],
          "limit" => 2,
          "include_attributes" => ["tokens"],
          "vector_encoding" => "base64"
        }),
      # Embed into a declared vector with and without dims/dtype.
      emb_declared:
        post.(ns.("ed"), %{
          "upsert_rows" => [%{"id" => "a", "text" => "Plants make sugar from sunlight."}],
          "distance_metric" => "cosine_distance",
          "schema" => %{
            "vec" => %{"type" => "[256]f32", "ann" => true},
            "text" => %{
              "type" => "string",
              "embed" => %{"model" => "openai/text-embedding-3-small", "attribute" => "vec"}
            }
          }
        }),
      emb_declared_meta: get.("/v1/namespaces/#{prefix}-ed/metadata"),
      emb_declared_query:
        post.(ns.("ed") <> "/query", %{
          "rank_by" => ["vec", "ANN", ["Embed", "photosynthesis", %{"model" => "openai/text-embedding-3-small"}]],
          "limit" => 1,
          "include_attributes" => ["vec"]
        }),
      emb_declared_nomodel:
        post.(ns.("ed") <> "/query", %{"rank_by" => ["vec", "ANN", ["Embed", "photosynthesis"]], "limit" => 1}),
      emb_knn:
        post.(ns.("ed") <> "/query", %{
          "rank_by" => ["text", "kNN", ["Embed", "photosynthesis"]],
          "filters" => ["id", "Eq", "a"],
          "limit" => 1
        }),
      emb_vector_dist:
        post.(ns.("ed") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 1,
          "compute_attributes" => %{
            "d" => ["vec", "VectorDist", ["Embed", "photosynthesis", %{"model" => "openai/text-embedding-3-small"}]]
          }
        }),
      emb_vector_dist_source:
        post.(ns.("ed") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "limit" => 1,
          "compute_attributes" => %{"d" => ["text", "VectorDist", ["Embed", "photosynthesis"]]}
        }),
      emb_supplied:
        post.(ns.("ed"), %{"upsert_rows" => [%{"id" => "b", "text" => "Anything", "vec" => List.duplicate(0.5, 256)}]}),
      emb_supplied_read:
        post.(ns.("ed") <> "/query", %{
          "rank_by" => ["id", "asc"],
          "filters" => ["id", "Eq", "b"],
          "limit" => 1,
          "include_attributes" => ["vec"]
        }),
      emb_disable: post.(ns.("ed"), %{"schema" => %{"text" => %{"type" => "string", "embed" => nil}}}),
      emb_disable_write: post.(ns.("ed"), %{"upsert_rows" => [%{"id" => "c", "text" => "No vector now"}]}),
      emb_disable_meta: get.("/v1/namespaces/#{prefix}-ed/metadata"),
      # Four embeds in one namespace, two into declared vectors.
      emb_four:
        post.(ns.("e4"), %{
          "upsert_rows" => [%{"id" => "a", "t1" => "one", "t2" => "two", "t3" => "three", "t4" => "four"}],
          "distance_metric" => "cosine_distance",
          "schema" => %{
            "t1" => %{"type" => "string", "embed" => "openai/text-embedding-3-small"},
            "t2" => %{
              "type" => "string",
              "embed" => %{"model" => "voyage/voyage-4-lite", "dtype" => "i8", "dims" => 256}
            },
            "t3" => %{"type" => "string", "embed" => %{"model" => "cohere/embed-v4.0", "attribute" => "v3"}},
            "v3" => %{"type" => "[512]f16", "ann" => true},
            "t4" => %{"type" => "string", "embed" => %{"model" => "baai/bge-m3", "dtype" => "f32"}}
          }
        }),
      emb_four_meta: get.("/v1/namespaces/#{prefix}-e4/metadata"),
      # limit.per and namespace listing with page_size.
      per0:
        post.(ns.("lp"), %{
          "upsert_rows" => for(i <- 1..6, do: %{"id" => "d#{i}", "cat" => "c#{rem(i, 2)}", "n" => i})
        }),
      per:
        post.(ns.("lp") <> "/query", %{
          "rank_by" => ["n", "desc"],
          "limit" => %{"total" => 10, "per" => %{"attributes" => ["cat"], "limit" => 2}},
          "include_attributes" => ["cat"]
        }),
      list_page: get.("/v1/namespaces?prefix=#{prefix}-&page_size=2"),
      delete_missing: Turbopuffer.Client.delete(client, "/v2/namespaces/#{prefix}-nope"),
      metadata_missing: get.("/v1/namespaces/#{prefix}-nope/metadata"),
      warm_missing: get.("/v1/namespaces/#{prefix}-nope/hint_cache_warm"),
      recall_filtered:
        post.("/v1/namespaces/#{prefix}-en/_debug/recall", %{"num" => 1, "top_k" => 1, "filters" => ["id", "Eq", "a"]}),
      copy_obj:
        post.(ns.("cp"), %{
          "copy_from_namespace" => %{"source_namespace" => "#{prefix}-lp", "source_region" => "gcp-us-central1"}
        }),
      patch_by_filter_partial:
        post.(ns.("lp"), %{
          "patch_by_filter" => %{"filters" => ["cat", "Eq", "c1"], "patch" => %{"n" => 0}},
          "patch_by_filter_allow_partial" => true,
          "return_affected_ids" => true
        }),
      delete_by_filter_partial:
        post.(ns.("lp"), %{
          "delete_by_filter" => ["cat", "Eq", "c0"],
          "delete_by_filter_allow_partial" => true,
          "return_affected_ids" => true
        }),
      columns:
        post.(ns.("co"), %{
          "upsert_columns" => %{"id" => ["a", "b"], "n" => [1, nil]},
          "patch_columns" => %{"id" => ["a"], "n" => [5]}
        })
    ]

    IO.puts("\n==PROBE==")
    for {label, result} <- results, do: IO.puts("#{label}: #{inspect(result, limit: 30, printable_limit: 300)}")
    IO.puts("==END PROBE==")
  end
end
