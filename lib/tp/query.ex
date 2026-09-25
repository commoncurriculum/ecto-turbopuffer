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

  The operators are Ecto's keyword fragments, e.g. `fragment(BM25: [c.markdown, ^text])`, which the adapter reads
  back by name. String fragments like `fragment("Glob(?, ?)", ...)` aren't turbopuffer operators.
  """

  # Each operator's turbopuffer name, its arities, the attribute capability it needs (see TP.Attribute), and its
  # role: a filter, a score ranked in its natural direction, a computed attribute, an `embed` vector query, a way
  # to combine scores, or `$dist`. The last argument of the longer arity is an options map, except for `embed`.
  @operators [
    {:fuzzy, "Fuzzy", [2, 3], :fuzzy, :filter},
    {:regex, "Regex", [2], :regex, :filter},
    {:glob, "Glob", [2], :glob, :filter},
    {:iglob, "IGlob", [2], :glob, :filter},
    {:contains, "Contains", [2], :filter, :filter},
    {:contains_any, "ContainsAny", [2], :filter, :filter},
    {:contains_all_tokens, "ContainsAllTokens", [2, 3], :full_text_search, :filter},
    {:contains_any_token, "ContainsAnyToken", [2, 3], :full_text_search, :filter},
    {:contains_token_sequence, "ContainsTokenSequence", [2], :full_text_search, :filter},
    {:any_lt, "AnyLt", [2], :filter, :filter},
    {:any_lte, "AnyLte", [2], :filter, :filter},
    {:any_gt, "AnyGt", [2], :filter, :filter},
    {:any_gte, "AnyGte", [2], :filter, :filter},
    {:bm25, "BM25", [2, 3], :full_text_search, {:score, :desc}},
    {:ann, "ANN", [2], :ann, {:score, :asc}},
    {:knn, "kNN", [2], :vector, {:score, :asc}},
    {:sparse_knn, "SparseKNN", [2], :sparse_knn, {:score, :desc}},
    {:vector_distance, "VectorDist", [2], :vector, :compute},
    {:embed, "Embed", [1, 2], nil, :embed},
    {:max_score, "Max", [2], nil, :max},
    {:dist, "$dist", [0], nil, :dist}
  ]

  for {name, op, arities, _needs, _role} <- @operators, arity <- arities do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defmacro unquote(name)(unquote_splicing(args)) do
      keyword = [{unquote(String.to_atom(op)), unquote(args)}]
      quote do: fragment(unquote(keyword))
    end
  end

  @doc false
  # The operator a keyword fragment names: `%{op:, arities:, needs:, role:}`, or nil when it isn't one.
  def __operator__(key)

  for {_name, op, arities, needs, role} <- @operators do
    def __operator__(unquote(String.to_atom(op))) do
      %{op: unquote(op), arities: unquote(arities), needs: unquote(needs), role: unquote(Macro.escape(role))}
    end
  end

  def __operator__(_key), do: nil
end
