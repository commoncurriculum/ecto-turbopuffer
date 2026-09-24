defmodule TP.AttributeTest do
  use ExUnit.Case, async: true

  defp entry(type, opts), do: TP.Attribute.schema_entry(TP.Types.decode(type), opts)

  describe "schema_entry/2" do
    test "renders only the options that were set" do
      assert entry("string", []) == %{"type" => "string"}
      assert entry("[]uuid", filterable: false) == %{"type" => "[]uuid", "filterable" => false}
    end

    test "full-text search takes a boolean or every documented BM25 setting" do
      assert entry("string", full_text_search: true) == %{"type" => "string", "full_text_search" => true}

      assert entry("[]string",
               full_text_search: [
                 tokenizer: :word_v3,
                 language: "french",
                 stemming: true,
                 remove_stopwords: true,
                 case_sensitive: false,
                 ascii_folding: true,
                 max_token_length: 64,
                 k1: 1.5,
                 b: 0.5,
                 k3: 8
               ],
               filterable: true
             ) == %{
               "type" => "[]string",
               "filterable" => true,
               "full_text_search" => %{
                 "tokenizer" => "word_v3",
                 "language" => "french",
                 "stemming" => true,
                 "remove_stopwords" => true,
                 "case_sensitive" => false,
                 "ascii_folding" => true,
                 "max_token_length" => 64,
                 "k1" => 1.5,
                 "b" => 0.5,
                 "k3" => 8
               }
             }
    end

    test "pattern filters" do
      assert entry("string", regex: true, glob: true, fuzzy: true) ==
               %{"type" => "string", "regex" => true, "glob" => true, "fuzzy" => true}

      assert entry("[]string", glob: true, fuzzy: true) == %{"type" => "[]string", "glob" => true, "fuzzy" => true}
    end

    test "the pre-tokenized tokenizer on []string" do
      assert entry("[]string", full_text_search: [tokenizer: :pre_tokenized_array, case_sensitive: true, k1: 1.5]) ==
               %{
                 "type" => "[]string",
                 "full_text_search" => %{"tokenizer" => "pre_tokenized_array", "case_sensitive" => true, "k1" => 1.5}
               }
    end

    test "names up to 128 bytes" do
      name = String.to_atom(String.duplicate("a", 128))
      assert entry("string", field: name) == %{"type" => "string"}
    end

    test "vector indexes" do
      assert entry("[3]f32", ann: true) == %{"type" => "[3]f32", "ann" => true}

      assert entry("[3]f16", ann: [distance_metric: :euclidean_squared]) ==
               %{"type" => "[3]f16", "ann" => %{"distance_metric" => "euclidean_squared"}}

      assert entry("[][3]f32", ann: [late_interaction: true, distance_metric: "cosine_distance"]) ==
               %{"type" => "[][3]f32", "ann" => %{"late_interaction" => true, "distance_metric" => "cosine_distance"}}

      assert entry("[][3]f32", ann: false) == %{"type" => "[][3]f32", "ann" => false}
      assert entry("[][3]f32", []) == %{"type" => "[][3]f32"}

      assert entry("{}f16", sparse_knn: [distance_metric: :dot_product]) ==
               %{"type" => "{}f16", "sparse_knn" => %{"distance_metric" => "dot_product"}}
    end

    test "native embedding" do
      assert entry("string", embed: "openai/text-embedding-3-small") ==
               %{"type" => "string", "embed" => "openai/text-embedding-3-small"}

      assert entry("string", embed: [model: "voyage/voyage-4-lite", attribute: "body_vector", dims: 512, dtype: :f16]) ==
               %{
                 "type" => "string",
                 "embed" => %{
                   "model" => "voyage/voyage-4-lite",
                   "attribute" => "body_vector",
                   "dims" => 512,
                   "dtype" => "f16"
                 }
               }
    end

    test "ignores Ecto's own field options" do
      assert entry("string", source: :planbookId, default: nil, field: :planbook_id, schema: __MODULE__) ==
               %{"type" => "string"}
    end

    test "ids are string, uint, or uuid with no index options" do
      for type <- ["string", "uint", "uuid"] do
        assert entry(type, primary_key: true, field: :id) == %{"type" => type}
      end

      assert_raise ArgumentError, ~r/ids must be string, uint, or uuid/, fn ->
        entry("int", primary_key: true, field: :id)
      end

      assert entry("string", primary_key: true, field: :stack_id, source: :id) == %{"type" => "string"}

      assert_raise ArgumentError, ~r/ids must be named `id` \(add `source: :id`/, fn ->
        entry("string", primary_key: true, field: :stack_id)
      end

      assert_raise ArgumentError, ~r/id can't take \[:full_text_search\]/, fn ->
        entry("string", primary_key: true, field: :id, full_text_search: true)
      end
    end
  end

  describe "schema_entry/2 rejects" do
    for {description, type, opts, message} <- [
          {"unknown options", "string", [full_text: true], ~r/unknown turbopuffer option\(s\) \[:full_text\]/},
          {"unknown nested options", "string", [full_text_search: [stem: true]],
           ~r/unknown :full_text_search option :stem/},
          {"full-text search on non-text", "int", [full_text_search: true], ~r/requires a string or \[\]string/},
          {"regex on non-text", "uuid", [regex: true], ~r/:regex requires a string attribute/},
          {"regex on []string", "[]string", [regex: true], ~r/:regex requires a string attribute/},
          {"glob on non-text", "int", [glob: true], ~r/:glob requires a string or \[\]string/},
          {"pre-tokenized strings", "string", [full_text_search: [tokenizer: :pre_tokenized_array]],
           ~r/pre_tokenized_array tokenizer requires a \[\]string attribute/},
          {"pre-tokenized with language settings", "[]string",
           [
             full_text_search: [
               tokenizer: :pre_tokenized_array,
               language: :english,
               stemming: true,
               remove_stopwords: true,
               case_sensitive: false
             ]
           ], ~r/can't be combined with language, stemming: true, remove_stopwords: true, case_sensitive: false/},
          {"names over 128 bytes", "string", [field: String.to_atom(String.duplicate("a", 129))],
           ~r/attribute names can be at most 128 bytes/},
          {"non-boolean flags", "string", [filterable: "yes"], ~r/:filterable must be a boolean/},
          {"unknown tokenizers", "string", [full_text_search: [tokenizer: :ngram]], ~r/:tokenizer must be one of/},
          {"unknown languages", "string", [full_text_search: [language: :klingon]], ~r/:language must be one of/},
          {"max_token_length out of range", "string", [full_text_search: [max_token_length: 255]],
           ~r/between 1 and 254/},
          {"b out of range", "string", [full_text_search: [b: 1.5]], ~r/:b must be a number between 0.0 and 1.0/},
          {"k1 of zero", "string", [full_text_search: [k1: 0]], ~r/:k1 must be a number greater than 0/},
          {"vectors without ann", "[3]f32", [], ~r/\[3\]f32 attributes require `ann: true`/},
          {"vectors with ann: false", "[3]i8", [ann: false], ~r/require `ann: true`/},
          {"unknown distance metrics", "[3]f32", [ann: [distance_metric: :dot_product]], ~r/:distance_metric must be/},
          {"late interaction on a plain vector", "[3]f32", [ann: [late_interaction: true]], ~r/unknown :ann option/},
          {"multi-vector ann: true", "[][3]f32", [ann: true], ~r/need `ann: \[late_interaction: true\]`/},
          {"multi-vector ann without late interaction", "[][3]f32", [ann: [distance_metric: :cosine_distance]],
           ~r/requires `late_interaction: true`/},
          {"ann on scalars", "string", [ann: true], ~r/:ann isn't supported on string/},
          {"filterable vectors", "[3]f32", [ann: true, filterable: true], ~r/\[3\]f32 attributes can't be filterable/},
          {"filterable bytes", "bytes", [filterable: true], ~r/bytes attributes can't be filterable/},
          {"filterable sparse vectors", "{}f16", [filterable: true], ~r/{}f16 attributes can't be filterable/},
          {"sparse_knn without a metric", "{}f16", [sparse_knn: []], ~r/sparse_knn requires :distance_metric/},
          {"sparse_knn on dense vectors", "[3]f32", [ann: true, sparse_knn: [distance_metric: :dot_product]],
           ~r/:sparse_knn isn't supported/},
          {"embed on []string", "[]string", [embed: "openai/text-embedding-3-small"],
           ~r/:embed isn't supported on \[\]string/},
          {"embed without a model", "string", [embed: [dims: 512]], ~r/embed requires :model/},
          {"embed with a bad dtype", "string", [embed: [model: "m", dtype: :f64]],
           ~r/:dtype must be one of f32, f16, i8/},
          {"$-prefixed names", "string", [field: :"$dist"], ~r/reserves attribute names starting with \$/},
          {"a non-key id", "string", [field: :id], ~r/reserves `id` for the primary key/}
        ] do
      test description do
        assert_raise ArgumentError, unquote(Macro.escape(message)), fn ->
          entry(unquote(type), unquote(opts))
        end
      end
    end
  end

  describe "filterable?/2" do
    for {description, type, opts, filterable} <- [
          {"plain attributes", "string", [], true},
          {"arrays", "[]uuid", [], true},
          {"full-text search", "string", [full_text_search: true], false},
          {"regex", "string", [regex: true], false},
          {"glob", "[]string", [glob: true], false},
          {"fuzzy", "string", [fuzzy: true], false},
          {"full-text search forced filterable", "string", [full_text_search: true, filterable: true], true},
          {"filterable: false", "int", [filterable: false], false},
          {"bytes", "bytes", [], false},
          {"vectors", "[3]f32", [ann: true], false},
          {"multi-vectors", "[][3]f32", [], false},
          {"sparse vectors", "{}f16", [], false}
        ] do
      test "#{description}: #{filterable}" do
        type = TP.Types.decode(unquote(type))
        assert TP.Attribute.filterable?(type, TP.Attribute.schema_entry(type, unquote(opts))) == unquote(filterable)
      end
    end
  end

  test "errors surface at compile time and name the field" do
    source = """
    defmodule TP.AttributeTest.Broken do
      use Ecto.Schema

      schema "broken" do
        field :embedding, TP, type: "[3]f32"
      end
    end
    """

    assert_raise ArgumentError, ~r/require `ann: true`.*field :embedding in TP.AttributeTest.Broken/, fn ->
      Code.compile_string(source)
    end
  end
end
