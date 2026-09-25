# Changelog

## Unreleased

### Features

- `Ecto.Adapters.Turbopuffer.metadata/3`, `update_metadata/4` (`read_only`, `pinning`), `warm_cache/3`,
  `delete_namespace/3`, `list_namespaces/2`, `update_schema/3`, `branch/3`, `copy/3` and `recall/3` cover
  turbopuffer's namespace endpoints, by schema.
- `TP.Query` ranks by `attribute/1`, `distance/2`, `saturate/2,3` and `decay/2,3`, takes filters as score boosts
  and numbers in `max_score/2`, and computes any non-vector score in a `select`. `highlight/1,2` selects the
  fragments of a field that match.
- `Repo.all(query, limit_per: {fields, n})` caps the rows sharing values of `fields`.
- `insert` and `insert_all` take `replace_if:`, a condition an existing document must match to be replaced, where
  `ref_new/1` is the value being written, and `disable_backpressure: true` for bulk loads.
- `use TP, num_shards: n` shards the namespace.
- Queries that select vectors read them as base64.

### Breaking changes

- Every schema with `TP` fields needs `use TP`, which checks the namespace when the schema compiles. The
  namespace's distance metric comes only from `use TP, distance_metric:`; vectors take `ann: true`, not
  `ann: [distance_metric: ...]`.
- `TP.dump/1`, `TP.load/2`, `TP.dump_attribute/3`, `TP.schema/1`, `TP.distance_metric/1` and `TP.attributes/1`
  are gone. `TP.Namespace.new/1` has the namespace's attributes, schema and distance metric, and Ecto's own
  `Ecto.Type.dump/2` and `Repo.load/2` do the rest.
- Dumping only encodes values that already fit the type: `"7"` no longer dumps as an int. Casting is unchanged.
- `TP.Attribute` holds typed fields (`capabilities`, `embed`, `options`) instead of the rendered schema entry, and
  needs the field's name.
- `insert_all` with the default `on_conflict: :raise` raises `TP.ConflictError`, which names the skipped ids,
  instead of `ArgumentError`. `update_all` raises `ArgumentError` for fields turbopuffer can't patch, like
  `update`.
- `group_by` needs a limit, since turbopuffer returns at most 10,000 groups.
- `<` and `<=` no longer match nil, and neither do negated ordering comparisons.
- Each named repo starts its own Finch pool, configured with `:pools`; repos started with `name: nil` share the
  driver's pool. `:finch_name` and `:json_library` are gone.
- String fragments like `fragment("Glob(?, ?)", ...)` are no longer read as turbopuffer operators.
- Ranking a vector field by `embed(text)` needs the model, `embed(^text, ^model)`, as turbopuffer requires.

### Bug fixes

- Reads no longer apply write limits: `Repo.get` with a 65-byte id returns nil instead of raising.
- A value over turbopuffer's limits raises with the limit it breaks, on insert and update.
- `update_all` declares the schema and distance metric, so an attribute it adds gets its declared type.
- `union_all` reads each query's rows with its own selected fields, flattens nested unions, and raises when the
  queries read different namespaces. With `rerank_by`, every query must select the same fields.
- `dynamic(true)` and other constant filters work.
- `like` with a nil pattern raises `Ecto.QueryError`.
- `limit + offset` over 10,000 raises before sending. `rerank_by` checks that there's a weight above 0 per query,
  that `rank_constant` is an integer above 0, and its limit and offset; `:batch_size` must be an integer above 0.
- `rerank_by` without a `union_all` raises.
- Sparse vector weights are range-checked like f16 vectors.
- base64 vectors in responses decode by the attribute's element type: 4 bytes for f32, 2 for f16 and 1 for i8, as
  turbopuffer sends them, though its docs say they're always f32.
- `vector_distance(field, embed(text))` raises, since turbopuffer can't compute it.
- `autogenerate: true` on a string or uint id fails at compile time.
- Namespace limits are always checked at compile time.

### Internals

- `TP.Query`'s operators are Ecto keyword fragments, listed in one table.
- One planner builds every request body, and an expression compiler builds the filters and scores in them.
- Tests run against turbopuffer, covering every endpoint, parameter, operator, type and embedding model in its
  docs, which `test/coverage_test.exs` checks. Offline tests cover only what the adapter refuses before sending.
