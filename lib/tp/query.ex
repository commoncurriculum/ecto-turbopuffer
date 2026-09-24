defmodule TP.Query do
  @moduledoc """
  turbopuffer's search operators for `Ecto.Query`. `import TP.Query` next to `import Ecto.Query`.

      from c in CardStack,
        where: c.planbook_id == ^planbook_id and fuzzy(c.title, ^"fotosynthesis"),
        order_by: [desc: bm25(c.markdown, ^text) + 2.0 * bm25(c.title, ^text)],
        limit: 20,
        select: {c, dist()}

  Ranking, for `order_by` (see `docs/turbopuffer/query.md#param-rank_by`):

    * `bm25(field, text)` - full-text relevance, highest first, so order it `desc`. Takes `^%{last_as_prefix: true}`
      as a third argument for type-ahead.
    * `ann(field, vector)` and `knn(field, vector)` - approximate and exact vector search, closest first, so order
      them `asc`. The vector can be `embed(^text)` to rank a field that turbopuffer embeds natively, or
      `embed(^text, ^model)` to name the model.
    * `sparse_knn(field, weights)` - sparse vector search, highest first.
    * `+` sums scores, `number * score` weights one, and `max_score(a, b)` takes the higher.

  `dist()` selects the rank score, turbopuffer's `$dist`. `bm25/2` and `vector_distance/2` in a `select` return
  that score for each row without ranking by it.

  Filters, for `where`, beyond Ecto's own `==`, `in`, `like`, `is_nil`, and so on
  (see `docs/turbopuffer/query.md#filtering-parameters`):

    * `fuzzy(field, text)` matches within an edit distance that grows with the query's length: exact under 6
      characters, 1 edit under 9, then 2. Pass `^%{max_edit_distance: [...], case_sensitive: false}` as a third
      argument to set them.
    * `regex(field, pattern)`, `glob(field, pattern)`, `iglob(field, pattern)`
    * `contains_all_tokens(field, text)`, `contains_any_token(field, text)`, `contains_token_sequence(field, text)`.
      The first two take `^%{last_as_prefix: true}` as a third argument.
    * `contains(array_field, value)`, `contains_any(array_field, values)`, and `any_lt/2`, `any_lte/2`,
      `any_gt/2`, `any_gte/2` for arrays. Ecto only allows `value in array_field` on its own array types, so use
      `contains/2` instead.

  Option arguments are maps, because Ecto doesn't allow keyword lists inside fragments.
  """

  @filters [
    fuzzy: "Fuzzy",
    regex: "Regex",
    glob: "Glob",
    iglob: "IGlob",
    contains: "Contains",
    contains_any: "ContainsAny",
    contains_all_tokens: "ContainsAllTokens",
    contains_any_token: "ContainsAnyToken",
    contains_token_sequence: "ContainsTokenSequence",
    any_lt: "AnyLt",
    any_lte: "AnyLte",
    any_gt: "AnyGt",
    any_gte: "AnyGte"
  ]

  for {name, op} <- @filters do
    template = op <> "(?, ?)"

    @doc false
    defmacro unquote(name)(field, value) do
      template = unquote(template)
      quote do: fragment(unquote(template), unquote(field), unquote(value))
    end
  end

  for {name, op} <- Keyword.take(@filters, [:fuzzy, :contains_all_tokens, :contains_any_token]) do
    template = op <> "(?, ?, ?)"

    @doc false
    defmacro unquote(name)(field, value, params) do
      template = unquote(template)
      quote do: fragment(unquote(template), unquote(field), unquote(value), unquote(params))
    end
  end

  @doc false
  defmacro bm25(field, text), do: quote(do: fragment("BM25(?, ?)", unquote(field), unquote(text)))

  @doc false
  defmacro bm25(field, text, params) do
    quote do: fragment("BM25(?, ?, ?)", unquote(field), unquote(text), unquote(params))
  end

  @doc false
  defmacro ann(field, vector), do: quote(do: fragment("ANN(?, ?)", unquote(field), unquote(vector)))

  @doc false
  defmacro knn(field, vector), do: quote(do: fragment("kNN(?, ?)", unquote(field), unquote(vector)))

  @doc false
  defmacro sparse_knn(field, weights), do: quote(do: fragment("SparseKNN(?, ?)", unquote(field), unquote(weights)))

  @doc false
  defmacro vector_distance(field, vector), do: quote(do: fragment("VectorDist(?, ?)", unquote(field), unquote(vector)))

  @doc false
  defmacro embed(text), do: quote(do: fragment("Embed(?)", unquote(text)))

  @doc false
  defmacro embed(text, model), do: quote(do: fragment("Embed(?, ?)", unquote(text), unquote(model)))

  @doc false
  defmacro max_score(a, b), do: quote(do: fragment("Max(?, ?)", unquote(a), unquote(b)))

  @doc false
  defmacro dist, do: quote(do: fragment("$dist"))
end
