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
      as a third argument for type-ahead. A `pre_tokenized_array` field takes a list of tokens instead of text.
    * `ann(field, vector)` and `knn(field, vector)` - approximate and exact vector search, closest first, so order
      them `asc`. The vector can be `embed(^text)` to rank a field that turbopuffer embeds natively, or
      `embed(^text, ^model)` to name the model, which ranking a vector field needs. `knn` needs a `where`.
    * `sparse_knn(field, weights)` - sparse vector search, highest first.
    * `attribute(field)` - a number field's value, highest first. turbopuffer only ranks by scores of at least 0, so
      a signed field's negative values score 0.
    * `distance(field, origin)` - how far a number or datetime field is from `origin`, farthest first. Usually
      passed to `decay/2`, to favour documents near the origin.
    * `saturate(score, midpoint)` maps a score into 0..1, reaching 0.5 at `midpoint`, and `decay(score, midpoint)`
      is its inverse, 1 at 0 and falling to 0.5 at `midpoint`. Both take an exponent as a third argument (1 by
      default). A datetime distance's midpoint can be milliseconds or a duration like `"6h"`.
    * A filter scores 1 where it matches and 0 elsewhere, so `bm25(c.title, ^text) + 2.0 * (c.species == "whale")`
      boosts whales. Documents scoring 0 overall aren't returned.
    * `+` sums scores, `number * score` weights one, and `max_score(a, b)` takes the higher, where either can be a
      number.

  Selecting, for `select`:

    * `dist()` - the rank score, turbopuffer's `$dist`.
    * Any score but a vector search, e.g. `bm25(c.markdown, ^text)` or `saturate(attribute(c.views), 100)`,
      computed for each row without ranking by it, and `vector_distance(field, vector)` for a vector's distance.
    * `highlight(field)` - the fragments of a full-text field that match the query's `bm25` on it, as maps with
      `"text"`. Pass a map of turbopuffer's options as a second argument (`fragment_by`, `fragment_limit`,
      `include_offsets`, and `rank_fragments_by`, which a query not ranked by the field's `bm25` needs). See
      `docs/turbopuffer/query.md#param-compute_attributes`.

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
    * `ref_new(field)`, only in `Repo.insert`'s `:replace_if`, is the value being written, e.g.
      `dynamic([c], c.updated_at < ref_new(c.updated_at))`.

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
  #   * `arities` - the longer one's last argument is an options map, except for `embed`, `saturate` and `decay`
  #   * `needs` - the attribute capability it needs (see TP.Attribute)
  #   * `role` - a filter, a score ranked best first in the given direction, a `:transform` of a score, `embed`'s
  #     vector query, a way to combine scores, `$dist`, `:highlight`, or `:ref_new`
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
    attribute: [op: "Attribute", arities: [1], needs: :rank, role: {:score, :desc}, select: true],
    distance: [op: "Dist", arities: [2], needs: :rank, role: {:score, :desc}, select: true],
    saturate: [op: "Saturate", arities: [2, 3], role: :transform, select: true],
    decay: [op: "Decay", arities: [2, 3], role: :transform, select: true],
    vector_distance: [op: "VectorDist", arities: [2], needs: :vector, select: true],
    highlight: [op: "Highlight", arities: [1, 2], needs: :full_text_search, role: :highlight],
    embed: [op: "Embed", arities: [1, 2], role: :embed],
    max_score: [op: "Max", arities: [2], role: :max],
    dist: [op: "$dist", arities: [0], role: :dist],
    ref_new: [op: "$ref_new", arities: [1], role: :ref_new]
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
