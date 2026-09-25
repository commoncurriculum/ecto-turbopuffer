# Changelog

## Unreleased

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
- Each repo starts its own Finch pool, configured with `:pools`. `:finch_name` and `:json_library` are gone.
- String fragments like `fragment("Glob(?, ?)", ...)` are no longer read as turbopuffer operators.

### Bug fixes

- Reads no longer apply write limits: `Repo.get` with a 65-byte id returns nil instead of raising.
- A value over turbopuffer's limits raises with the limit it breaks, on insert and update.
- `update_all` declares the schema and distance metric, so an attribute it adds gets its declared type.
- `union_all` reads each query's rows with its own selected fields, flattens nested unions, and raises when the
  queries read different namespaces. With `rerank_by`, every query must select the same fields.
- `dynamic(true)` and other constant filters work.
- `like` with a nil pattern raises `Ecto.QueryError`.
- `limit + offset` over 10,000 raises before sending, and `rerank_by` checks its weights and window.
- `rerank_by` without a `union_all` raises.
- Sparse vector weights are range-checked like f16 vectors.
- `autogenerate: true` on a string or uint id fails at compile time.
- Namespace limits are always checked at compile time.

### Internals

- `TP.Query`'s operators are Ecto keyword fragments, listed in one table.
- One planner builds every request body, and an expression compiler builds the filters and scores in them.
- Most tests run offline.
