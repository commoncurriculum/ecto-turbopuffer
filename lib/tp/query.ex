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
      `embed(^text, ^model)` to name the model, which ranking a vector field needs.
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

  # turbopuffer requires max_edit_distance, and each step's min_query_chars must be at least 3 * (distance + 1).
  @fuzzy_distances %{
    "max_edit_distance" => [
      %{"min_query_chars" => 3, "distance" => 0},
      %{"min_query_chars" => 6, "distance" => 1},
      %{"min_query_chars" => 9, "distance" => 2}
    ]
  }

  # Each macro's turbopuffer operator:
  #   * `arities` - the longer one's last argument is an options map, except for `embed`
  #   * `needs` - the attribute capability it needs (see TP.Attribute)
  #   * `role` - a filter, a score ranked best first in the given direction, `embed`'s vector query, a way to
  #     combine scores, or `$dist`
  #   * `defaults` - the options sent when none are given
  #   * `select` - whether turbopuffer computes it per row in a select (compute_attributes)
  #   * `vector_query` - whether its second argument is a vector that can be `embed(text)`
  @operators [
    fuzzy: [op: "Fuzzy", arities: [2, 3], needs: :fuzzy, role: :filter, defaults: @fuzzy_distances],
    regex: [op: "Regex", arities: [2], needs: :regex, role: :filter],
    glob: [op: "Glob", arities: [2], needs: :glob, role: :filter],
    iglob: [op: "IGlob", arities: [2], needs: :glob, role: :filter],
    contains: [op: "Contains", arities: [2], needs: :filter, role: :filter],
    contains_any: [op: "ContainsAny", arities: [2], needs: :filter, role: :filter],
    contains_all_tokens: [op: "ContainsAllTokens", arities: [2, 3], needs: :full_text_search, role: :filter],
    contains_any_token: [op: "ContainsAnyToken", arities: [2, 3], needs: :full_text_search, role: :filter],
    contains_token_sequence: [op: "ContainsTokenSequence", arities: [2], needs: :full_text_search, role: :filter],
    any_lt: [op: "AnyLt", arities: [2], needs: :filter, role: :filter],
    any_lte: [op: "AnyLte", arities: [2], needs: :filter, role: :filter],
    any_gt: [op: "AnyGt", arities: [2], needs: :filter, role: :filter],
    any_gte: [op: "AnyGte", arities: [2], needs: :filter, role: :filter],
    bm25: [op: "BM25", arities: [2, 3], needs: :full_text_search, role: {:score, :desc}, select: true],
    ann: [op: "ANN", arities: [2], needs: :ann, role: {:score, :asc}, vector_query: true],
    knn: [op: "kNN", arities: [2], needs: :vector, role: {:score, :asc}, vector_query: true],
    sparse_knn: [op: "SparseKNN", arities: [2], needs: :sparse_knn, role: {:score, :desc}],
    vector_distance: [op: "VectorDist", arities: [2], needs: :vector, select: true, vector_query: true],
    embed: [op: "Embed", arities: [1, 2], role: :embed],
    max_score: [op: "Max", arities: [2], role: :max],
    dist: [op: "$dist", arities: [0], role: :dist]
  ]

  for {name, spec} <- @operators, arity <- spec[:arities] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defmacro unquote(name)(unquote_splicing(args)) do
      keyword = [{unquote(String.to_atom(spec[:op])), unquote(args)}]
      quote do: fragment(unquote(keyword))
    end
  end

  @doc false
  # The operator a keyword fragment names, as a map of the fields above, or nil when it isn't one.
  def __operator__(key)

  for {_name, spec} <- @operators do
    operator = Map.merge(%{needs: nil, role: nil, defaults: nil, select: false, vector_query: false}, Map.new(spec))
    def __operator__(unquote(String.to_atom(spec[:op]))), do: unquote(Macro.escape(operator))
  end

  def __operator__(_key), do: nil
end
