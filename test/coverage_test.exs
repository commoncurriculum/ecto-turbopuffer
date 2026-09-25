defmodule TP.CoverageTest do
  # Every endpoint, parameter, response field, operator, type and text setting in turbopuffer's API docs
  # (docs/turbopuffer), and the test that exercises it against turbopuffer, or why none can. Re-vendoring docs
  # that add something fails this until it's covered.
  use ExUnit.Case, async: true

  @docs Path.expand("../docs/turbopuffer", __DIR__)
  @tests Path.expand(".", __DIR__)

  # {file, a phrase from the test's name}
  @writes_insert {"writes_test.exs", "won't overwrite an existing id by default"}
  @writes_conflict {"writes_test.exs", "raising TP.ConflictError by default"}
  @writes_replace_if {"writes_test.exs", "replace_if replaces an existing document"}
  @writes_patch {"writes_test.exs", "patches the changed fields"}
  @writes_lock {"writes_test.exs", "or an optimistic lock doesn't match"}
  @writes_delete {"writes_test.exs", "delete deletes a document"}
  @writes_by_filter {"writes_test.exs", "patch and delete by filter"}
  @writes_backpressure {"writes_test.exs", "disable_backpressure writes"}
  @query_comparisons {"query_test.exs", "comparisons, in, and nil checks"}
  @query_logic {"query_test.exs", "and, or, not, or_where"}
  @query_arrays {"query_test.exs", "arrays"}
  @query_globs {"query_test.exs", "like, ilike and globs"}
  @query_regex {"query_test.exs", "regex"}
  @query_text {"query_test.exs", "fuzzy and token filters"}
  @query_order {"query_test.exs", "by fields, with an offset"}
  @query_limit_per {"query_test.exs", "limit_per caps"}
  @query_select {"query_test.exs", "fields, maps, and literals"}
  @query_aggregates {"query_test.exs", "count, sum, group_by"}
  @query_consistency {"query_test.exs", "consistency: :eventual"}
  @query_telemetry {"query_test.exs", "telemetry reports each request"}
  @query_errors {"query_test.exs", "turbopuffer's errors raise TP.Error"}
  @search_bm25 {"search_test.exs", "bm25 ranks by relevance"}
  @search_combine {"search_test.exs", "sums, weights, and takes the max"}
  @search_prefix {"search_test.exs", "last_as_prefix"}
  @search_text_settings {"search_test.exs", "follows each field's tokenizer"}
  @search_attribute {"search_test.exs", "attribute/1 scores a number"}
  @search_saturate {"search_test.exs", "saturate and decay"}
  @search_distance {"search_test.exs", "distance/2 scores"}
  @search_filter_score {"search_test.exs", "a filter scores 1 where it matches"}
  @search_compute {"search_test.exs", "a select computes any score"}
  @search_highlight {"search_test.exs", "takes turbopuffer's options"}
  @search_vectors {"search_test.exs", "ranks f32, f16 and i8 vectors"}
  @search_knn {"search_test.exs", "knn ranks exactly within a filter"}
  @search_sparse {"search_test.exs", "sparse_knn ranks"}
  @search_multi {"search_test.exs", "runs a multi-query"}
  @search_rrf {"search_test.exs", "rerank_by: :rrf fuses"}
  @namespaces_metadata {"namespaces_test.exs", "metadata describes a namespace"}
  @namespaces_pinning {"namespaces_test.exs", "pinning reserves compute"}
  @namespaces_read_only {"namespaces_test.exs", "read_only rejects writes"}
  @namespaces_warm {"namespaces_test.exs", "warm_cache hints"}
  @namespaces_list {"namespaces_test.exs", "list_namespaces pages through"}
  @namespaces_branch {"namespaces_test.exs", "branch makes an independent"}
  @namespaces_copy {"namespaces_test.exs", "copy copies every document"}
  @namespaces_shards {"namespaces_test.exs", "num_shards partitions"}
  @namespaces_recall {"namespaces_test.exs", "recall measures the vector index"}
  @types_round_trip {"types_test.exs", "every type round-trips"}
  @types_schema {"types_test.exs", "turbopuffer stores the schema TP declares"}
  @embed_defaults {"embedding_test.exs", "embeds text with its defaults"}
  @embed_declared {"embedding_test.exs", "embeds text into a declared"}
  @embed_existing {"embedding_test.exs", "alongside vectors computed elsewhere"}
  @embed_ann_knn {"embedding_test.exs", "and ranks text with ann or knn"}

  @billing_query_fields ~w(billable_logical_bytes_queried billable_logical_bytes_returned)
  @performance_fields ~w(approx_namespace_size cache_hit_ratio cache_temperature exhaustive_search_count
                         last_included_write_at query_execution_ms server_total_ms)

  @coverage %{
              "endpoint POST /v2/namespaces/:namespace" => @writes_insert,
              "endpoint POST /v2/namespaces/:namespace/query" => @query_comparisons,
              "endpoint DELETE /v2/namespaces/:namespace" => @namespaces_list,
              "endpoint GET /v1/namespaces" => @namespaces_list,
              "endpoint GET /v1/namespaces/:namespace/metadata" => @namespaces_metadata,
              "endpoint PATCH /v1/namespaces/:namespace/metadata" => @namespaces_read_only,
              "endpoint GET /v1/namespaces/:namespace/hint_cache_warm" => @namespaces_warm,
              "endpoint POST /v1/namespaces/:namespace/_debug/recall" => @namespaces_recall,
              "write.md Upsert" => {:not_applicable, "a latency figure, not a parameter"},
              "write.md upsert_rows" => @writes_insert,
              "write.md upsert_columns" => {:not_applicable, "upsert_rows is the same write, laid out by row"},
              "write.md patch_rows" => @writes_patch,
              "write.md patch_columns" => {:not_applicable, "patch_rows is the same write, laid out by row"},
              "write.md deletes" => @writes_delete,
              "write.md upsert_condition" => @writes_replace_if,
              "write.md patch_condition" => @writes_lock,
              "write.md delete_condition" => @writes_lock,
              "write.md patch_by_filter" => @writes_by_filter,
              "write.md delete_by_filter" => @writes_by_filter,
              "write.md patch_by_filter_allow_partial" =>
                {:not_supported,
                 "update_all fails past turbopuffer's 50k-document limit rather than patching part of the match, " <>
                   "since repeating a partial patch never ends when the patch doesn't change what the filter matches"},
              "write.md delete_by_filter_allow_partial" =>
                {:not_supported,
                 "delete_all fails past turbopuffer's 5M-document limit rather than deleting part of it"},
              "write.md rows_remaining" => {:not_supported, "only set by the partial writes above"},
              "write.md return_affected_ids" => @writes_conflict,
              "write.md upserted_ids" => @writes_conflict,
              "write.md patched_ids" => {:not_supported, "Ecto's update_all and update return counts, not ids"},
              "write.md deleted_ids" => {:not_supported, "Ecto's delete_all and delete return counts, not ids"},
              "write.md rows_affected" => @writes_by_filter,
              "write.md rows_upserted" => {:not_applicable, "rows_affected, which the adapter reads, is the sum"},
              "write.md rows_patched" => {:not_applicable, "rows_affected, which the adapter reads, is the sum"},
              "write.md rows_deleted" => {:not_applicable, "rows_affected, which the adapter reads, is the sum"},
              "write.md distance_metric" => @types_schema,
              "write.md copy_from_namespace" => @namespaces_copy,
              "write.md source_namespace" => @namespaces_copy,
              "write.md source_region" => @namespaces_copy,
              "write.md source_api_key" =>
                {:untestable, "copy's :from_api_key copies from another organization, which needs a second account"},
              "write.md branch_from_namespace" => @namespaces_branch,
              "write.md schema" => @types_schema,
              "write.md sharding" => @namespaces_shards,
              "write.md num_shards" => @namespaces_shards,
              "write.md encryption" =>
                {:not_supported, "customer-managed encryption needs turbopuffer's scale plan and a cloud KMS key"},
              "write.md disable_backpressure" => @writes_backpressure,
              "write.md billing" => @writes_backpressure,
              "write.md billable_logical_bytes_written" => @writes_backpressure,
              "write.md billable_logical_bytes_queried" => @query_telemetry,
              "write.md billable_logical_bytes_returned" => @query_telemetry,
              "write.md query" => {:not_applicable, "billing's query figures, reported to telemetry like the rest"},
              "write.md performance" => @query_telemetry,
              "write.md server_total_ms" => @query_telemetry,
              "write.md type" => @types_round_trip,
              "write.md ann" => @search_vectors,
              "write.md filterable" => @types_schema,
              "write.md regex" => @query_regex,
              "write.md glob" => @query_globs,
              "write.md fuzzy" => @query_text,
              "write.md full_text_search" => @search_bm25,
              "write.md tokenizer" => @search_text_settings,
              "write.md case_sensitive" => @search_text_settings,
              "write.md language" => @search_text_settings,
              "write.md stemming" => @search_text_settings,
              "write.md remove_stopwords" => @types_schema,
              "write.md ascii_folding" => @search_text_settings,
              "write.md max_token_length" => @types_schema,
              "write.md k1" => @types_schema,
              "write.md b" => @types_schema,
              "write.md k3" => @types_schema,
              "write.md sparse_knn" => @search_sparse,
              "write.md embed" => @embed_defaults,
              "write.md model" => @embed_declared,
              "write.md attribute" => @embed_declared,
              "write.md dims" => @embed_declared,
              "write.md dtype" => @embed_declared,
              "query.md rank_by" => @search_bm25,
              "query.md top_k" => @query_aggregates,
              "query.md offset" => @query_order,
              "query.md filters" => @query_comparisons,
              "query.md include_attributes" => @query_select,
              "query.md exclude_attributes" => {:not_applicable, "a select names the attributes to include"},
              "query.md compute_attributes" => @search_compute,
              "query.md fragment_by" => @search_highlight,
              "query.md rank_fragments_by" => @search_highlight,
              "query.md fragment_limit" => @search_highlight,
              "query.md include_offsets" => @search_highlight,
              "query.md limit" => @query_order,
              "query.md total" => @query_limit_per,
              "query.md per" => @query_limit_per,
              "query.md attributes" => @query_limit_per,
              "query.md aggregate_by" => @query_aggregates,
              "query.md group_by" => @query_aggregates,
              "query.md queries" => @search_multi,
              "query.md rerank_by" => @search_rrf,
              "query.md vector_encoding" => @search_vectors,
              "query.md consistency" => @query_consistency,
              "query.md rows" => @query_comparisons,
              "query.md results" => @search_multi,
              "query.md aggregations" => @query_aggregates,
              "query.md aggregation_groups" => @query_aggregates,
              "query.md billing" => @query_telemetry,
              "query.md performance" => @query_telemetry,
              "query.md model" => @embed_existing,
              "query.md exponent" => @search_saturate,
              "query.md max_edit_distance" => @query_text,
              "query.md case_sensitive" => @query_text,
              "query.md And" => @query_logic,
              "query.md Or" => @query_logic,
              "query.md Not" => @query_logic,
              "query.md Eq" => @query_comparisons,
              "query.md NotEq" => @query_comparisons,
              "query.md In" => @query_comparisons,
              "query.md NotIn" => @query_comparisons,
              "query.md Lt" => @query_comparisons,
              "query.md Lte" => @query_comparisons,
              "query.md Gt" => @query_comparisons,
              "query.md Gte" => @query_comparisons,
              "query.md Contains" => @query_arrays,
              "query.md NotContains" => @query_arrays,
              "query.md ContainsAny" => @query_arrays,
              "query.md NotContainsAny" => @query_arrays,
              "query.md AnyLt" => @query_arrays,
              "query.md AnyLte" => @query_arrays,
              "query.md AnyGt" => @query_arrays,
              "query.md AnyGte" => @query_arrays,
              "query.md Glob" => @query_globs,
              "query.md NotGlob" => @query_globs,
              "query.md IGlob" => @query_globs,
              "query.md NotIGlob" => @query_globs,
              "query.md Regex" => @query_regex,
              "query.md Fuzzy" => @query_text,
              "query.md ContainsAllTokens" => @query_text,
              "query.md ContainsTokenSequence" => @query_text,
              "query.md ContainsAnyToken" => @query_text,
              "rank ANN" => @search_vectors,
              "rank kNN" => @search_knn,
              "rank BM25" => @search_bm25,
              "rank SparseKNN" => @search_sparse,
              "rank Sum" => @search_combine,
              "rank Max" => @search_combine,
              "rank Product" => @search_combine,
              "rank Attribute" => @search_attribute,
              "rank Saturate" => @search_saturate,
              "rank Decay" => @search_saturate,
              "rank Dist" => @search_distance,
              "rank Embed" => @embed_ann_knn,
              "rank VectorDist" => @search_knn,
              "rank Highlight" => @search_highlight,
              "rank RRF" => @search_rrf,
              "rank last_as_prefix" => @search_prefix,
              "rank filters" => @search_filter_score,
              "rank late_interaction" =>
                {:untestable, "vector arrays are in private beta, and turbopuffer rejects them for this account"},
              "metadata.md Metadata" => {:not_applicable, "a latency figure, not a field"},
              "metadata.md schema" => @types_schema,
              "metadata.md approx_logical_bytes" => @namespaces_metadata,
              "metadata.md approx_row_count" => @namespaces_metadata,
              "metadata.md created_at" => @namespaces_metadata,
              "metadata.md last_write_at" => @namespaces_metadata,
              "metadata.md updated_at" => @namespaces_metadata,
              "metadata.md encryption" => @namespaces_metadata,
              "metadata.md index" => @namespaces_metadata,
              "metadata.md status" => @namespaces_metadata,
              "metadata.md unindexed_bytes" => {:not_applicable, "only present while turbopuffer is indexing"},
              "metadata.md pinning" => @namespaces_pinning,
              "metadata.md replicas" => @namespaces_pinning,
              "metadata.md branching" => @namespaces_branch,
              "metadata.md parent" => @namespaces_branch,
              "metadata.md sharding" => @namespaces_shards,
              "metadata.md num_shards" => @namespaces_shards,
              "metadata.md read_only" => @namespaces_read_only,
              "namespaces.md cursor" => @namespaces_list,
              "namespaces.md prefix" => @namespaces_list,
              "namespaces.md page_size" => @namespaces_list,
              "namespaces.md namespaces" => @namespaces_list,
              "namespaces.md next_cursor" => @namespaces_list,
              "namespaces.md id" => @namespaces_list,
              "recall.md num" => @namespaces_recall,
              "recall.md top_k" => @namespaces_recall,
              "recall.md filters" => @namespaces_recall,
              "recall.md rank_by" => @namespaces_recall,
              "recall.md avg_recall" => @namespaces_recall,
              "recall.md avg_exhaustive_count" => @namespaces_recall,
              "recall.md avg_ann_count" => @namespaces_recall,
              "type [][N]f32" =>
                {:untestable, "vector arrays are in private beta, and turbopuffer rejects them for this account"},
              "api async requests" =>
                {:not_supported, "copy and recall wait for turbopuffer to finish, as its own clients do"},
              "api error responses" => @query_errors,
              "api 429" =>
                {:untestable, "turbopuffer returns 429 under load, which the driver retries (Turbopuffer.Retry)"}
            }
            |> Map.merge(Map.new(@billing_query_fields, &{"query.md #{&1}", @query_telemetry}))
            |> Map.merge(Map.new(@performance_fields, &{"query.md #{&1}", @query_telemetry}))
            |> Map.merge(
              Map.new(
                ~w(string int uint float uuid datetime bool bytes []string []int []uint []float []uuid []datetime []bool
                   [N]f32 [N]f16 [N]i8 {}f16),
                &{"type #{&1}", @types_round_trip}
              )
            )
            |> Map.merge(Map.new(~w(word_v0 word_v1 word_v2 word_v3 word_v4), &{"tokenizer #{&1}", @types_schema}))
            |> Map.put("tokenizer pre_tokenized_array", @search_text_settings)
            |> Map.merge(
              Map.new(
                ~w(arabic danish dutch english finnish french german greek hungarian italian norwegian portuguese
                   romanian russian spanish swedish tamil turkish),
                &{"language #{&1}", @types_schema}
              )
            )

  test "every documented part of turbopuffer's API is tested, or says why it can't be" do
    documented = MapSet.new(documented())
    covered = MapSet.new(Map.keys(@coverage))

    documented_but_not_covered = documented |> MapSet.difference(covered) |> Enum.sort()
    covered_but_no_longer_documented = covered |> MapSet.difference(documented) |> Enum.sort()
    assert documented_but_not_covered == []
    assert covered_but_no_longer_documented == []

    for {item, {reason, why}} <- @coverage, is_atom(reason) do
      assert reason in [:not_supported, :not_applicable, :untestable] and is_binary(why), item
    end

    for {item, {file, phrase}} <- @coverage, is_binary(file) do
      source = File.read!(Path.join(test_dir(file), file))

      assert source =~ ~r/test "[^"]*#{Regex.escape(phrase)}/,
             "#{item}: no test in #{file} named like #{inspect(phrase)}"
    end
  end

  defp test_dir("coverage_test.exs"), do: @tests
  defp test_dir(_file), do: Path.join(@tests, "ecto/adapters/turbopuffer")

  defp documented do
    read = fn file -> File.read!(Path.join(@docs, file)) end
    fields = fn file -> Regex.scan(~r/^ *\*\*([A-Za-z_$]+)\*\*/m, read.(file), capture: :all_but_first) end
    options = fn file -> Regex.scan(~r/^ *[-*] `([a-z][a-z0-9_]*)` \(/m, read.(file), capture: :all_but_first) end

    endpoints =
      for file <- File.ls!(@docs),
          String.ends_with?(file, ".md"),
          [endpoint] <- Regex.scan(~r/^(?:GET|POST|PATCH|DELETE) \/v\d\/[a-z_:\/]+/m, read.(file)),
          do: "endpoint " <> endpoint

    parameters =
      for file <- ~w(write.md query.md metadata.md namespaces.md recall.md),
          [name] <- fields.(file) ++ options.(file),
          do: "#{file} #{name}"

    type_section =
      read.("write.md") |> String.split("**type** string") |> Enum.at(1) |> String.split("All attributes") |> hd()

    types = for [type] <- Regex.scan(~r/^- `([^`]+)`:/m, type_section, capture: :all_but_first), do: "type " <> type

    fts = read.("fts.md")

    tokenizers =
      for [name] <- Regex.scan(~r/^- `(word_v\d|pre_tokenized_array)`/m, fts, capture: :all_but_first),
          do: "tokenizer " <> name

    languages = for [name] <- Regex.scan(~r/<span>([a-z]+)/, fts, capture: :all_but_first), do: "language " <> name

    # Ranking functions and query features the reference describes in prose rather than as parameters.
    query = read.("query.md")

    ranks =
      for {name, phrase} <- [
            {"ANN", ~s("ANN")},
            {"kNN", ~s("kNN")},
            {"BM25", ~s("BM25")},
            {"SparseKNN", ~s("SparseKNN")},
            {"Sum", ~s("Sum")},
            {"Max", ~s("Max")},
            {"Product", ~s("Product")},
            {"Attribute", ~s("Attribute")},
            {"Saturate", ~s("Saturate")},
            {"Decay", ~s("Decay")},
            {"Dist", ~s("Dist")},
            {"Embed", ~s("Embed")},
            {"VectorDist", ~s("VectorDist")},
            {"Highlight", ~s("Highlight")},
            {"RRF", ~s("RRF")},
            {"last_as_prefix", "last_as_prefix"},
            {"filters", "### Rank by filter"},
            {"late_interaction", "late_interaction"}
          ],
          String.contains?(query, phrase),
          do: "rank " <> name

    overview = read.("api-overview.md")

    api =
      for {name, phrase} <- [
            {"async requests", "## Asynchronous requests"},
            {"error responses", "## Error responses"},
            {"429", "HTTP 429"}
          ],
          String.contains?(overview, phrase),
          do: "api " <> name

    endpoints ++ parameters ++ types ++ tokenizers ++ languages ++ ranks ++ api
  end
end
