alias TP.Test.Embedding

# One module per model, so the models run concurrently.
for {model, default_dims, supported, i8?} = entry <- Embedding.models() do
  defmodule Module.concat(Ecto.Adapters.Turbopuffer.EmbeddingTest, Macro.camelize(Embedding.slug(model))) do
    use TP.Test.Case, async: true

    @model model
    @docs [
      %{id: "photosynthesis", text: "Plants turn sunlight into sugar through photosynthesis."},
      %{id: "revolution", text: "The storming of the Bastille began the French Revolution."}
    ]
    @question "how do leaves make food?"

    @default_type "[#{default_dims}]f16"

    test "#{model} embeds text with its defaults, into #{@default_type}" do
      schema = Embedding.default(@model)
      Repo.insert_all(schema, @docs)

      assert Repo.all(from d in schema, order_by: ann(d.text, embed(^@question)), limit: 2, select: d.id) ==
               ~w(photosynthesis revolution)

      assert Turbopuffer.metadata(Repo, schema)["schema"]["embed_text"]["type"] == @default_type
    end

    for dims <- supported, dtype <- Embedding.dtypes(i8?) do
      @schema Embedding.schema(model, dims, dtype)
      @dims dims
      @dtype dtype

      test "#{model} embeds text into a declared [#{dims}]#{dtype} vector" do
        Repo.insert_all(@schema, @docs)

        assert [{"photosynthesis", vector}, {"revolution", _}] =
                 Repo.all(
                   from d in @schema,
                     order_by: ann(d.text, embed(^@question)),
                     limit: 2,
                     select: {d.id, d.vector}
                 )

        assert length(vector) == @dims

        if @dtype == :i8,
          do: assert(Enum.all?(vector, &(is_integer(&1) and &1 in -128..127))),
          else: assert(Enum.all?(vector, &is_float/1))
      end
    end

    @entry entry
    @supported supported

    test "#{model} rejects the dimensions and element types it doesn't support" do
      for {dims, dtype} <- Embedding.unsupported(@entry) do
        message =
          if dims == 7,
            do:
              ~r/dimensions \(7\) aren't supported by `#{Regex.escape(@model)}`, valid dims are \[#{Enum.join(@supported, ",")}\]/,
            else: ~r/type \(i8\) isn't supported by `#{Regex.escape(@model)}`, valid types are \[f16,f32\]/

        schema = Embedding.schema(@model, dims, dtype)
        assert_raise TP.Error, message, fn -> Repo.insert_all(schema, @docs) end
      end
    end
  end
end

defmodule Ecto.Adapters.Turbopuffer.NativeEmbeddingTest do
  use TP.Test.Case, async: true

  alias TP.Test.{EmbeddedNote, Lesson, MultiEmbed, Note}

  @model "openai/text-embedding-3-small"

  test "embeds up to 30 documents per write, and ranks text with ann or knn" do
    texts = [
      "Plants turn sunlight into sugar through photosynthesis.",
      "The storming of the Bastille began the French Revolution.",
      "Mitosis splits one cell into two identical cells."
      | for(i <- 1..28, do: "Practice problem #{i}: add the fractions.")
    ]

    {{31, nil}, writes} = requests(fn -> Repo.insert_all(Lesson, Enum.map(texts, &%{markdown: &1})) end)
    assert Enum.map(writes, &length(&1.query["upsert_rows"])) == [30, 1]

    [photosynthesis | _] =
      Repo.all(from l in Lesson, order_by: ann(l.markdown, embed(^"how do leaves make food?")), limit: 3)

    assert photosynthesis.markdown =~ "photosynthesis"

    exact =
      from l in Lesson,
        where: l.id != ^photosynthesis.id,
        order_by: knn(l.markdown, embed(^"cells dividing")),
        limit: 1,
        select: l.markdown

    assert Repo.all(exact) == ["Mitosis splits one cell into two identical cells."]
  end

  test "embeds text into a declared vector, alongside vectors computed elsewhere" do
    # Vectors from another model, written before native embedding was on.
    Repo.insert!(%Note{
      id: "walrus",
      text: "Walruses and narwhals live in the Arctic.",
      vector: List.duplicate(0.1, 256)
    })

    # Embedding an existing attribute into an existing vector is an online schema change.
    :ok = Turbopuffer.update_schema(Repo, EmbeddedNote)

    Repo.insert_all(EmbeddedNote, [
      %{id: "plants", text: "Plants turn sunlight into sugar."},
      %{id: "fish", text: "Pufferfish and clownfish live on reefs."}
    ])

    # A vector written alongside embedded text is stored as it is.
    Repo.insert!(%EmbeddedNote{id: "supplied", text: "Anything at all.", vector: List.duplicate(0.5, 256)})
    assert Repo.get!(Note, "supplied").vector == List.duplicate(0.5, 256)

    question = "how do leaves make food?"
    assert [%{id: "plants"} | _] = Repo.all(from n in EmbeddedNote, order_by: ann(n.text, embed(^question)), limit: 2)

    # Ranking the vector itself needs the model, as for a namespace whose vectors are only queried natively.
    assert [%{id: "plants"} | _] =
             Repo.all(from n in Note, order_by: ann(n.vector, embed(^question, ^@model)), limit: 2)

    assert %{"schema" => %{"text" => %{"embed" => %{"attribute" => "vector", "model" => @model}}}} =
             Turbopuffer.metadata(Repo, Note)
  end

  test "embeds four attributes of one namespace, each its own way" do
    docs = [
      %{id: "photosynthesis", text: "Plants turn sunlight into sugar through photosynthesis."},
      %{id: "revolution", text: "The storming of the Bastille began the French Revolution."}
    ]

    Repo.insert_all(
      MultiEmbed,
      Enum.map(docs, &%{id: &1.id, default: &1.text, quantized: &1.text, declared: &1.text, wide: &1.text})
    )

    question = "how do leaves make food?"

    for query <- [
          from(m in MultiEmbed, order_by: ann(m.default, embed(^question)), limit: 1, select: m.id),
          from(m in MultiEmbed, order_by: ann(m.quantized, embed(^question)), limit: 1, select: m.id),
          from(m in MultiEmbed, order_by: ann(m.declared, embed(^question)), limit: 1, select: m.id),
          from(m in MultiEmbed,
            order_by: ann(m.declared_vector, embed(^question, "cohere/embed-v4.0")),
            limit: 1,
            select: m.id
          ),
          from(m in MultiEmbed, order_by: ann(m.wide, embed(^question)), limit: 1, select: m.id)
        ] do
      assert Repo.all(query) == ["photosynthesis"]
    end

    assert %{"schema" => stored} = Turbopuffer.metadata(Repo, MultiEmbed)

    assert Map.new(~w(embed_default embed_quantized declared_vector embed_wide), &{&1, stored[&1]["type"]}) == %{
             "embed_default" => "[1536]f16",
             "embed_quantized" => "[256]i8",
             "declared_vector" => "[512]f16",
             "embed_wide" => "[1024]f32"
           }

    assert [vector] = Repo.all(from m in MultiEmbed, where: m.id == "photosynthesis", select: m.declared_vector)
    assert length(vector) == 512
  end
end
