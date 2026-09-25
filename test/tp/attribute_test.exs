defmodule TP.AttributeTest do
  use ExUnit.Case, async: true

  defp attribute(type, opts \\ []), do: TP.Attribute.new(Keyword.merge([type: type, field: :attr], opts))
  defp entry(type, opts \\ []), do: TP.Attribute.to_schema(attribute(type, opts))

  describe "to_schema/1" do
    test "renders only the options that were set" do
      assert entry("string") == %{"type" => "string"}
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

    test "vector indexes" do
      assert entry("[3]f32", ann: true) == %{"type" => "[3]f32", "ann" => true}

      assert entry("[][3]f32", ann: [late_interaction: true]) ==
               %{"type" => "[][3]f32", "ann" => %{"late_interaction" => true}}

      assert entry("[][3]f32", ann: false) == %{"type" => "[][3]f32", "ann" => false}
      assert entry("[][3]f32") == %{"type" => "[][3]f32"}

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
  end

  describe "new/1" do
    test "names the attribute after the field's source" do
      assert %TP.Attribute{field: :planbook_id, name: "planbookId"} =
               attribute("string", field: :planbook_id, source: :planbookId)

      name = String.to_atom(String.duplicate("a", 128))
      assert attribute("string", field: name).name == Atom.to_string(name)
    end

    test "resolves native embedding's model and target vector" do
      assert attribute("string", field: :body, embed: "openai/text-embedding-3-small").embed ==
               %{model: "openai/text-embedding-3-small", target: "embed_body", dims: nil, dtype: nil}

      assert attribute("string", embed: [model: "m", attribute: "body_vector", dims: 512, dtype: :f16]).embed ==
               %{model: "m", target: "body_vector", dims: 512, dtype: "f16"}

      assert attribute("string").embed == nil
    end

    test "ids are string, uint, or uuid, named id, with no index options" do
      for type <- ["string", "uint", "uuid"] do
        assert %TP.Attribute{primary_key: true, filterable: false} = attribute(type, primary_key: true, field: :id)
      end

      assert attribute("string", primary_key: true, field: :stack_id, source: :id).name == "id"
      assert attribute("uuid", primary_key: true, field: :id, autogenerate: true).type == :uuid
    end
  end

  describe "new/1 rejects" do
    for {description, type, opts, message} <- [
          {"unknown options", "string", [full_text: true], ~r/unknown turbopuffer option\(s\) \[:full_text\]/},
          {"unknown nested options", "string", [full_text_search: [stem: true]],
           ~r/unknown :full_text_search option :stem/},
          {"full-text search on non-text", "int", [full_text_search: true],
           ~r/:full_text_search requires a string or \[\]string attribute, not int/},
          {"regex on non-text", "uuid", [regex: true], ~r/:regex requires a string attribute, not uuid/},
          {"regex on []string", "[]string", [regex: true], ~r/:regex requires a string attribute/},
          {"glob on non-text", "int", [glob: true], ~r/:glob requires a string or \[\]string attribute/},
          {"unsupported options set to false", "int", [glob: false], ~r/:glob requires a string or \[\]string/},
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
          {"vectors with ann: false", "[3]i8", [ann: false], ~r/\[3\]i8 attributes take `ann: true`, got: false/},
          {"a distance metric in ann", "[3]f32", [ann: [distance_metric: :cosine_distance]],
           ~r/set the namespace's distance metric with `use TP, distance_metric: ...`/},
          {"multi-vector ann: true", "[][3]f32", [ann: true], ~r/take `ann: \[late_interaction: true\]`/},
          {"multi-vector ann without late interaction", "[][3]f32", [ann: [late_interaction: false]],
           ~r/take `ann: \[late_interaction: true\]`/},
          {"unknown multi-vector ann options", "[][3]f32", [ann: [distance_metric: :cosine_distance]],
           ~r/unknown :ann option :distance_metric/},
          {"ann on scalars", "string", [ann: true],
           ~r/:ann requires a \[N\] vector or \[\]\[N\] multi-vector attribute, not string/},
          {"filterable vectors", "[3]f32", [ann: true, filterable: true], ~r/\[3\]f32 attributes can't be filterable/},
          {"filterable bytes", "bytes", [filterable: true], ~r/bytes attributes can't be filterable/},
          {"filterable sparse vectors", "{}f16", [filterable: true], ~r/{}f16 attributes can't be filterable/},
          {"sparse_knn without a metric", "{}f16", [sparse_knn: []], ~r/sparse_knn requires :distance_metric/},
          {"sparse_knn on dense vectors", "[3]f32", [ann: true, sparse_knn: [distance_metric: :dot_product]],
           ~r/:sparse_knn requires a {}f16 attribute/},
          {"embed on []string", "[]string", [embed: "openai/text-embedding-3-small"],
           ~r/:embed requires a string attribute, not \[\]string/},
          {"embed without a model", "string", [embed: [dims: 512]], ~r/embed requires :model/},
          {"embed with a bad dtype", "string", [embed: [model: "m", dtype: :f64]],
           ~r/:dtype must be one of f32, f16, i8/},
          {"$-prefixed names", "string", [field: :"$dist"], ~r/reserves attribute names starting with \$/},
          {"a non-key id", "string", [field: :id], ~r/reserves `id` for the primary key/},
          {"int ids", "int", [primary_key: true, field: :id], ~r/ids must be string, uint, or uuid; got int/},
          {"ids not named id", "string", [primary_key: true, field: :stack_id],
           ~r/ids must be named `id` \(add `source: :id`/},
          {"ids with index options", "string", [primary_key: true, field: :id, full_text_search: true],
           ~r/turbopuffer ids can't take :full_text_search/},
          {"autogenerated strings", "string", [primary_key: true, field: :id, autogenerate: true],
           ~r/TP can only autogenerate uuid values, not string/},
          {"autogenerated uints", "uint", [primary_key: true, field: :id, autogenerate: true],
           ~r/TP can only autogenerate uuid values, not uint/},
          {"no field", "string", [field: nil], ~r/TP needs the field's name/}
        ] do
      test description do
        assert_raise ArgumentError, unquote(Macro.escape(message)), fn ->
          attribute(unquote(type), unquote(Macro.escape(opts)))
        end
      end
    end
  end

  describe "filterable" do
    for {description, type, opts, filterable} <- [
          {"plain attributes", "string", [], true},
          {"arrays", "[]uuid", [], true},
          {"full-text search", "string", [full_text_search: true], false},
          {"regex", "string", [regex: true], false},
          {"glob", "[]string", [glob: true], false},
          {"fuzzy", "string", [fuzzy: true], false},
          {"a disabled index", "string", [fuzzy: false], true},
          {"full-text search forced filterable", "string", [full_text_search: true, filterable: true], true},
          {"filterable: false", "int", [filterable: false], false},
          {"bytes", "bytes", [], false},
          {"vectors", "[3]f32", [ann: true], false},
          {"multi-vectors", "[][3]f32", [], false},
          {"sparse vectors", "{}f16", [], false}
        ] do
      test "#{description}: #{filterable}" do
        assert attribute(unquote(type), unquote(opts)).filterable == unquote(filterable)
      end
    end
  end

  describe "capabilities and missing/2" do
    test "follow the type and indexes" do
      assert attribute("string", primary_key: true, field: :id).capabilities == [:filter, :glob]
      assert attribute("string").capabilities == [:filter, :glob, :patch]
      assert attribute("string", glob: true, filterable: false).capabilities == [:glob, :patch]

      assert attribute("string", regex: true, fuzzy: true, full_text_search: true).capabilities ==
               [:regex, :fuzzy, :full_text_search, :patch]

      assert attribute("string", embed: "m").capabilities == [:filter, :glob, :embed]
      assert attribute("[3]f32", ann: true).capabilities == [:ann, :vector, :embed]
      assert attribute("[][3]f32", ann: [late_interaction: true]).capabilities == [:ann, :vector]
      assert attribute("[][3]f32", ann: false).capabilities == [:vector]
      assert attribute("{}f16").capabilities == [:sparse_knn, :patch]
    end

    test "missing/2 says why a query can't use the attribute" do
      markdown = attribute("string", field: :markdown, full_text_search: true)
      assert TP.Attribute.missing(markdown, :full_text_search) == nil
      assert TP.Attribute.missing(markdown, :filter) == ":markdown isn't filterable"
      assert TP.Attribute.missing(markdown, :fuzzy) == ":markdown needs `fuzzy:`"
      assert TP.Attribute.missing(markdown, :glob) == ":markdown needs `glob: true` or to be filterable"
      assert TP.Attribute.missing(markdown, :ann) == ":markdown has no ANN index"
      assert TP.Attribute.missing(markdown, :vector) == ":markdown isn't a vector"
      assert TP.Attribute.missing(markdown, :embed) == ":markdown isn't embedded text or a vector"
      assert TP.Attribute.missing(markdown, :sparse_knn) == ":markdown isn't a sparse vector"

      assert TP.Attribute.missing(attribute("[3]f32", field: :vector, ann: true), :patch) =~
               ":vector can't be patched: turbopuffer can't patch vectors or the text it embeds"

      assert TP.Attribute.missing(attribute("string", primary_key: true, field: :id), :patch) ==
               ":id can't be patched: turbopuffer ids can't change"
    end
  end

  test "errors surface at compile time and name the field" do
    source = """
    defmodule TP.AttributeTest.Broken do
      use Ecto.Schema
      use TP, distance_metric: :cosine_distance

      @primary_key {:id, TP, type: "string", autogenerate: false}
      schema "broken" do
        field :embedding, TP, type: "[3]f32"
      end
    end
    """

    assert_raise ArgumentError, ~r/require `ann: true` \(field :embedding in TP.AttributeTest.Broken\)/, fn ->
      Code.compile_string(source)
    end
  end
end
