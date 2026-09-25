defmodule TP.NamespaceTest do
  # turbopuffer's namespace rules TP checks before anything is sent: when a schema compiles, and for each document
  # written.
  use ExUnit.Case, async: true

  alias TP.Test.{CardStack, Lesson}

  defmodule EmbeddedVectorDoc do
    use Ecto.Schema
    use TP, distance_metric: :euclidean_squared

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embedded_vector_docs" do
      field :markdown, TP, type: "string", embed: [model: "openai/text-embedding-3-small", attribute: "markdown_vector"]
      field :markdown_vector, TP, type: "[256]f32", ann: true
      field :notes, TP, type: "bytes"
      field :tags, TP, type: "[]string"
      field :sparse, TP, type: "{}f16"
    end
  end

  # Compiles a schema, where `use TP` checks the namespace.
  defp compile(fields, opts) do
    use_tp =
      if metric = Keyword.get(opts, :distance_metric, :cosine_distance),
        do: "use TP, distance_metric: #{inspect(metric)}",
        else: "use TP"

    Code.compile_string("""
    defmodule TP.NamespaceTest.Compiled#{System.unique_integer([:positive])} do
      use Ecto.Schema
      #{use_tp}

      #{Keyword.get(opts, :primary_key, ~s(@primary_key {:id, TP, type: "string", autogenerate: false}))}
      schema #{inspect(Keyword.get(opts, :source, "docs"))} do
        #{fields}
      end
    end
    """)
  end

  test "use TP checks turbopuffer's namespace limits when the schema compiles" do
    for {fields, opts, message} <- [
          {~s(field :jurisdiction, :map), [], ~r/\.jurisdiction has type :map.*flatten embedded/},
          {~s(field :title, TP, type: "string"), [primary_key: "@primary_key false"], ~r/needs one TP primary key/},
          {~s(field :title, TP, type: "string"), [source: "card stacks/v1"],
           ~r/namespace names must match \[A-Za-z0-9-_.\]\{1,128\}, got: "card stacks\/v1"/},
          {~S[for i <- 1..1024, do: field(:"a#{i}", TP, type: "int")], [],
           ~r/has 1025 attributes; turbopuffer allows 1024/},
          {~S"""
           for i <- 1..7, do: field(:"vector_#{i}", TP, type: "[2]f32", ann: true)
           field :summary, TP, type: "string", embed: "m"
           field :body, TP, type: "string", embed: "m"
           """, [], ~r/has 9 vector columns, counting embedded attributes' computed vectors; turbopuffer allows 8/},
          {~S[for i <- 1..5, do: field(:"t#{i}", TP, type: "string", embed: "m")], [],
           ~r/embeds 5 attributes; turbopuffer allows 4/},
          {~s(field :markdown, TP, type: "string", embed: "m"), [distance_metric: nil],
           ~r/has vector columns, so turbopuffer needs a distance metric: add `use TP/},
          {~s(field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec"]), [],
           ~r/embed attribute "vec" must be an \[N\] vector field in the schema/},
          {"""
           field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dims: 4]
           field :vec, TP, type: "[3]f32", ann: true
           """, [], ~r/embed dims 4 don't match vec's 3 dimensions/},
          {"""
           field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dtype: :f16]
           field :vec, TP, type: "[3]f32", ann: true
           """, [], ~r/embed dtype f16 doesn't match vec's f32 elements/}
        ] do
      assert_raise ArgumentError, message, fn -> compile(fields, opts) end
    end

    assert [{_, _}] =
             compile(
               """
               field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dims: 3, dtype: :f32]
               field :vec, TP, type: "[3]f32", ann: true
               """,
               []
             )
  end

  test "a document needs an id and every vector, unless native embedding fills the vector from its text" do
    card_stacks = TP.Namespace.new(CardStack)
    embedded = TP.Namespace.new(EmbeddedVectorDoc)

    assert_raise ArgumentError, ~r/cannot write TP.Test.CardStack without an id/, fn ->
      TP.Namespace.row!(card_stacks, id: nil, vector: "AAAA")
    end

    assert_raise ArgumentError, ~r/without :vector: turbopuffer upserts must include every vector attribute/, fn ->
      TP.Namespace.row!(card_stacks, id: "a", vector: nil)
    end

    assert TP.Namespace.row!(embedded, id: "a", markdown: "# Fractions", markdown_vector: nil) ==
             %{"id" => "a", "markdown" => "# Fractions"}

    assert_raise ArgumentError, ~r/without :markdown_vector/, fn ->
      TP.Namespace.row!(embedded, id: "a", markdown: nil, markdown_vector: nil)
    end
  end

  test "documents and patches keep to turbopuffer's value limits, and patches to what it can patch" do
    card_stacks = TP.Namespace.new(CardStack)
    embedded = TP.Namespace.new(EmbeddedVectorDoc)
    big = String.duplicate("a", 4_097)

    for {namespace, fields, message} <- [
          {card_stacks, [id: String.duplicate("a", 65)],
           ~r/CardStack.id: turbopuffer ids can be at most 64 bytes, and it's 65/},
          {card_stacks, [planbook_id: big],
           ~r/CardStack.planbook_id: it's 4097 bytes, over turbopuffer's 4 KiB limit for filterable/},
          {card_stacks, [title: big], ~r/4 KiB limit for filterable values \(set `filterable: false`/},
          {card_stacks, [standard_ids: ["s1", big]], ~r/standard_ids: it's 4097 bytes/},
          {embedded, [tags: [String.duplicate("a", 5_000_000), String.duplicate("a", 5_000_000)]],
           ~r/tags: it's 10000000 bytes, over turbopuffer's 8 MiB limit per value/},
          {embedded, [notes: Base.encode64(:binary.copy(<<0>>, 8 * 1024 * 1024 + 1))],
           ~r/notes: it's 8388609 bytes, over turbopuffer's 8 MiB limit/},
          {embedded, [sparse: Map.new(1..1_025, &{"d#{&1}", 1.0})], ~r/sparse vectors can have at most 1024 dimensions/}
        ] do
      base = if namespace == card_stacks, do: [id: "a", vector: "AAAA"], else: [id: "a", markdown: "m"]
      assert_raise ArgumentError, message, fn -> TP.Namespace.row!(namespace, Keyword.merge(base, fields)) end
    end

    # bytes count at their decoded size, and a non-filterable string isn't held to the filterable limit.
    assert %{"notes" => _} =
             TP.Namespace.row!(embedded, id: "a", markdown: "m", notes: Base.encode64(:binary.copy(<<0>>, 6_000_000)))

    assert %{"markdown" => ^big} = TP.Namespace.row!(card_stacks, id: "a", markdown: big, vector: "AAAA")

    for {schema, fields, message} <- [
          {CardStack, [planbook_id: big], ~r/4 KiB limit for filterable values/},
          {CardStack, [vector: "AAAA"],
           ~r/:vector can't be patched: turbopuffer can't patch vectors .* \(TP.Test.CardStack\)/},
          {Lesson, [markdown: "x"],
           ~r/:markdown can't be patched: turbopuffer can't patch vectors or the text it embeds/},
          {CardStack, [id: "b"], ~r/:id can't be patched: turbopuffer ids can't change/}
        ] do
      assert_raise ArgumentError, message, fn -> TP.Namespace.patch!(TP.Namespace.new(schema), fields) end
    end
  end
end
