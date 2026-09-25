defmodule TP.NamespaceTest do
  use ExUnit.Case, async: true

  alias TP.Test.{CardStack, Everything, Lesson}

  defmodule UuidDoc do
    use Ecto.Schema
    use TP

    @primary_key {:id, TP, type: "uuid", autogenerate: false}
    schema "uuid_docs" do
      field :title, TP, type: "string"
    end
  end

  defmodule EmbeddedVectorDoc do
    use Ecto.Schema
    use TP, distance_metric: :euclidean_squared

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embedded_vector_docs" do
      field :markdown, TP,
        type: "string",
        embed: [model: "openai/text-embedding-3-small", attribute: "markdown_vector", dims: 3]

      field :markdown_vector, TP, type: "[3]f32", ann: true
      field :notes, TP, type: "bytes"
      field :tags, TP, type: "[]string"
      field :sparse, TP, type: "{}f16"
    end
  end

  # Compiles a schema, where `use TP` checks the namespace.
  defp compile(fields, opts \\ []) do
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

  describe "new/1" do
    test "collects the schema's attributes, turbopuffer schema, and distance metric" do
      namespace = TP.Namespace.new(Everything)

      assert Enum.map(namespace.attributes, & &1.field) == Everything.__schema__(:fields)
      assert namespace.by_name["planbookId"].field == :planbook_id
      assert namespace.distance_metric == "cosine_distance"
      refute namespace.embeds?
      assert TP.Namespace.new(Lesson).embeds?

      assert TP.Namespace.new(CardStack).schema == %{
               "title" => %{
                 "type" => "string",
                 "full_text_search" => true,
                 "glob" => true,
                 "fuzzy" => true,
                 "filterable" => true
               },
               "markdown" => %{"type" => "string", "full_text_search" => true},
               "planbook_id" => %{"type" => "string"},
               "standard_ids" => %{"type" => "[]string"},
               "position" => %{"type" => "int"},
               "vector" => %{"type" => "[3]f32", "ann" => true}
             }
    end

    test "declares non-string ids, which turbopuffer doesn't infer" do
      assert TP.Namespace.new(UuidDoc).schema == %{"id" => "uuid", "title" => %{"type" => "string"}}
      assert TP.Namespace.new(UuidDoc).distance_metric == nil
    end
  end

  describe "write_params/1" do
    test "declares the schema, and the distance metric when there is one" do
      assert TP.Namespace.write_params(TP.Namespace.new(UuidDoc)) == %{
               "schema" => %{"id" => "uuid", "title" => %{"type" => "string"}}
             }

      assert %{"distance_metric" => "cosine_distance", "schema" => %{"vector" => _}} =
               TP.Namespace.write_params(TP.Namespace.new(CardStack))
    end
  end

  describe "use TP checks turbopuffer's namespace limits at compile time" do
    test "accepts an embed that writes into a declared vector" do
      assert [{_, _}] =
               compile("""
               field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dims: 3, dtype: :f32]
               field :vec, TP, type: "[3]f32", ann: true
               """)
    end

    for {description, fields, opts, message} <- [
          {"fields that aren't TP", ~s(field :jurisdiction, :map), [],
           ~r/\.jurisdiction has type :map.*flatten embedded/},
          {"no TP primary key", ~s(field :title, TP, type: "string"), [primary_key: "@primary_key false"],
           ~r/needs one TP primary key/},
          {"invalid namespace names", ~s(field :title, TP, type: "string"), [source: "card stacks/v1"],
           ~r/namespace names must match \[A-Za-z0-9-_.\]\{1,128\}, got: "card stacks\/v1"/},
          {"too many attributes", ~S[for i <- 1..1024, do: field(:"a#{i}", TP, type: "int")], [],
           ~r/has 1025 attributes; turbopuffer allows 1024/},
          {"too many vector columns, counting embeddings",
           ~S"""
           for i <- 1..7, do: field(:"vector_#{i}", TP, type: "[2]f32", ann: true)
           field :summary, TP, type: "string", embed: "m"
           field :body, TP, type: "string", embed: "m"
           """, [], ~r/has 9 vector columns, counting embedded attributes' computed vectors; turbopuffer allows 8/},
          {"too many embeds", ~S[for i <- 1..5, do: field(:"t#{i}", TP, type: "string", embed: "m")], [],
           ~r/embeds 5 attributes; turbopuffer allows 4/},
          {"vector columns without a distance metric", ~s(field :markdown, TP, type: "string", embed: "m"),
           [distance_metric: nil], ~r/has vector columns, so turbopuffer needs a distance metric: add `use TP/},
          {"an embed into an undeclared vector",
           ~s(field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec"]), [],
           ~r/embed attribute "vec" must be an \[N\] vector field in the schema/},
          {"an embed into a mismatched vector",
           """
           field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dims: 4]
           field :vec, TP, type: "[3]f32", ann: true
           """, [], ~r/embed dims 4 don't match vec's 3 dimensions/},
          {"an embed with a mismatched dtype",
           """
           field :markdown, TP, type: "string", embed: [model: "m", attribute: "vec", dtype: :f16]
           field :vec, TP, type: "[3]f32", ann: true
           """, [], ~r/embed dtype f16 doesn't match vec's f32 elements/}
        ] do
      test "rejects #{description}" do
        assert_raise ArgumentError, unquote(Macro.escape(message)), fn ->
          compile(unquote(fields), unquote(opts))
        end
      end
    end
  end

  describe "name!/2" do
    test "prepends the prefix with a dash" do
      assert TP.Namespace.name!("card_stacks", nil) == "card_stacks"
      assert TP.Namespace.name!("card_stacks", "staging") == "staging-card_stacks"
    end

    test "rejects names turbopuffer doesn't allow" do
      assert_raise ArgumentError, ~r/must match \[A-Za-z0-9-_.\]\{1,128\}, got: "card stacks-card_stacks"/, fn ->
        TP.Namespace.name!("card_stacks", "card stacks")
      end

      assert_raise ArgumentError, ~r/got: "#{String.duplicate("a", 129)}"/, fn ->
        TP.Namespace.name!(String.duplicate("a", 129), nil)
      end
    end
  end

  describe "row!/2" do
    setup do
      {:ok, card_stacks: TP.Namespace.new(CardStack), embedded: TP.Namespace.new(EmbeddedVectorDoc)}
    end

    test "keys the dumped values by attribute name", %{card_stacks: ns} do
      assert TP.Namespace.row!(ns, id: "a", title: nil, vector: "AAAA") == %{
               "id" => "a",
               "title" => nil,
               "vector" => "AAAA"
             }
    end

    test "needs an id and every vector", %{card_stacks: ns} do
      assert_raise ArgumentError, ~r/cannot write TP.Test.CardStack without an id/, fn ->
        TP.Namespace.row!(ns, id: nil, vector: "AAAA")
      end

      assert_raise ArgumentError, ~r/without :vector: turbopuffer upserts must include every vector attribute/, fn ->
        TP.Namespace.row!(ns, id: "a", vector: nil)
      end
    end

    test "lets native embedding fill a vector from its text", %{embedded: ns} do
      assert TP.Namespace.row!(ns, id: "a", markdown: "# Fractions", markdown_vector: nil) ==
               %{"id" => "a", "markdown" => "# Fractions"}

      assert_raise ArgumentError, ~r/without :markdown_vector/, fn ->
        TP.Namespace.row!(ns, id: "a", markdown: nil, markdown_vector: nil)
      end
    end

    test "enforces turbopuffer's value limits", %{card_stacks: ns, embedded: embedded} do
      big = String.duplicate("a", 4_097)

      for {namespace, fields, message} <- [
            {ns, [id: String.duplicate("a", 65)],
             ~r/CardStack.id: turbopuffer ids can be at most 64 bytes, and it's 65/},
            {ns, [planbook_id: big],
             ~r/CardStack.planbook_id: it's 4097 bytes, over turbopuffer's 4 KiB limit for filterable/},
            {ns, [title: big], ~r/4 KiB limit for filterable values \(set `filterable: false`/},
            {ns, [standard_ids: ["s1", big]], ~r/standard_ids: it's 4097 bytes/},
            {embedded, [tags: [String.duplicate("a", 5_000_000), String.duplicate("a", 5_000_000)]],
             ~r/tags: it's 10000000 bytes, over turbopuffer's 8 MiB limit per value/},
            {embedded, [notes: Base.encode64(:binary.copy(<<0>>, 8 * 1024 * 1024 + 1))],
             ~r/notes: it's 8388609 bytes, over turbopuffer's 8 MiB limit/},
            {embedded, [sparse: Map.new(1..1_025, &{"d#{&1}", 1.0})],
             ~r/sparse vectors can have at most 1024 dimensions/}
          ] do
        base = if namespace == ns, do: [id: "a", vector: "AAAA"], else: [id: "a", markdown: "m"]

        assert_raise ArgumentError, message, fn -> TP.Namespace.row!(namespace, Keyword.merge(base, fields)) end
      end

      assert %{"markdown" => ^big} = TP.Namespace.row!(ns, id: "a", markdown: big, vector: "AAAA")
      assert %{"notes" => _} = TP.Namespace.row!(embedded, id: "a", markdown: "m", notes: Base.encode64(<<0, 1>>))
    end
  end

  describe "patch!/2" do
    test "keys the fields by attribute name, and checks the limits" do
      ns = TP.Namespace.new(CardStack)
      assert TP.Namespace.patch!(ns, title: "Decimals", position: 2) == %{"title" => "Decimals", "position" => 2}

      assert_raise ArgumentError, ~r/4 KiB limit for filterable values/, fn ->
        TP.Namespace.patch!(ns, planbook_id: String.duplicate("a", 4_097))
      end
    end

    test "refuses what turbopuffer can't patch" do
      for {schema, fields, message} <- [
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
end
