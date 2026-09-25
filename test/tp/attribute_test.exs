defmodule TP.AttributeTest do
  # The field options TP refuses when a schema compiles. types_test.exs checks turbopuffer stores the ones it
  # accepts as declared.
  use ExUnit.Case, async: true

  defp attribute(type, opts), do: TP.Attribute.new(Keyword.merge([type: type, field: :attr], opts))

  test "rejects options turbopuffer doesn't allow" do
    for {type, opts, message} <- [
          {"string", [full_text: true], ~r/unknown turbopuffer option\(s\) \[:full_text\]/},
          {"string", [full_text_search: [stem: true]], ~r/unknown :full_text_search option :stem/},
          {"int", [full_text_search: true], ~r/:full_text_search requires a string or \[\]string attribute, not int/},
          {"uuid", [regex: true], ~r/:regex requires a string attribute, not uuid/},
          {"[]string", [regex: true], ~r/:regex requires a string attribute/},
          {"int", [glob: true], ~r/:glob requires a string or \[\]string attribute/},
          {"int", [glob: false], ~r/:glob requires a string or \[\]string/},
          {"string", [full_text_search: [tokenizer: :pre_tokenized_array]],
           ~r/pre_tokenized_array tokenizer requires a \[\]string attribute/},
          {"[]string",
           [
             full_text_search: [
               tokenizer: :pre_tokenized_array,
               language: :english,
               stemming: true,
               remove_stopwords: true,
               case_sensitive: false
             ]
           ], ~r/can't be combined with language, stemming: true, remove_stopwords: true, case_sensitive: false/},
          {"string", [field: String.to_atom(String.duplicate("a", 129))], ~r/attribute names can be at most 128 bytes/},
          {"string", [filterable: "yes"], ~r/:filterable must be a boolean/},
          {"string", [full_text_search: [tokenizer: :ngram]], ~r/:tokenizer must be one of/},
          {"string", [full_text_search: [language: :klingon]], ~r/:language must be one of/},
          {"string", [full_text_search: [max_token_length: 255]], ~r/between 1 and 254/},
          {"string", [full_text_search: [b: 1.5]], ~r/:b must be a number between 0.0 and 1.0/},
          {"string", [full_text_search: [k1: 0]], ~r/:k1 must be a number greater than 0/},
          {"string", [full_text_search: [stemming: true, case_sensitive: true]],
           ~r/doesn't stem or remove stopwords from case-sensitive text/},
          {"string", [full_text_search: [remove_stopwords: true, case_sensitive: true]],
           ~r/doesn't stem or remove stopwords from case-sensitive text/},
          {"[3]f32", [], ~r/\[3\]f32 attributes require `ann: true`/},
          {"[3]i8", [ann: false], ~r/\[3\]i8 attributes take `ann: true`, got: false/},
          {"[3]f32", [ann: [distance_metric: :cosine_distance]],
           ~r/set the namespace's distance metric with `use TP, distance_metric: ...`/},
          {"[][3]f32", [ann: true], ~r/take `ann: \[late_interaction: true\]`/},
          {"[][3]f32", [ann: [late_interaction: false]], ~r/take `ann: \[late_interaction: true\]`/},
          {"[][3]f32", [ann: [distance_metric: :cosine_distance]], ~r/unknown :ann option :distance_metric/},
          {"string", [ann: true], ~r/:ann requires a \[N\] vector or \[\]\[N\] multi-vector attribute, not string/},
          {"[3]f32", [ann: true, filterable: true], ~r/\[3\]f32 attributes can't be filterable/},
          {"bytes", [filterable: true], ~r/bytes attributes can't be filterable/},
          {"{}f16", [filterable: true], ~r/{}f16 attributes can't be filterable/},
          {"{}f16", [sparse_knn: []], ~r/sparse_knn requires :distance_metric/},
          {"[3]f32", [ann: true, sparse_knn: [distance_metric: :dot_product]],
           ~r/:sparse_knn requires a {}f16 attribute/},
          {"[]string", [embed: "openai/text-embedding-3-small"],
           ~r/:embed requires a string attribute, not \[\]string/},
          {"string", [embed: [dims: 512]], ~r/embed requires :model/},
          {"string", [embed: [model: "m", dims: 0]], ~r/:dims must be a positive integer/},
          {"string", [embed: [model: "m", dtype: :f64]], ~r/:dtype must be one of f32, f16, i8/},
          {"string", [embed: [model: "m", size: 3]], ~r/unknown :embed option :size/},
          {"string", [field: :"$dist"], ~r/reserves attribute names starting with \$/},
          {"string", [field: :id], ~r/reserves `id` for the primary key/},
          {"int", [primary_key: true, field: :id], ~r/ids must be string, uint, or uuid; got int/},
          {"string", [primary_key: true, field: :stack_id], ~r/ids must be named `id` \(add `source: :id`/},
          {"string", [primary_key: true, field: :id, full_text_search: true],
           ~r/turbopuffer ids can't take :full_text_search/},
          {"string", [primary_key: true, field: :id, autogenerate: true],
           ~r/TP can only autogenerate uuid values, not string/},
          {"uint", [primary_key: true, field: :id, autogenerate: true],
           ~r/TP can only autogenerate uuid values, not uint/},
          {"string", [field: nil], ~r/TP needs the field's name/}
        ] do
      assert_raise ArgumentError, message, fn -> attribute(type, opts) end
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
