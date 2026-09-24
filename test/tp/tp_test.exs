defmodule TPTest do
  use ExUnit.Case, async: true

  defmodule Doc do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "docs" do
      field :title, TP, type: "string", full_text_search: [language: :english, stemming: true]
      field :markdown, TP, type: "string", full_text_search: true, embed: "openai/text-embedding-3-small"
      field :notation, TP, type: "string", glob: true, filterable: true
      field :planbook_id, TP, type: "string", source: :planbookId
      field :standard_ids, TP, type: "[]string"
      field :position, TP, type: "int"
      field :views, TP, type: "uint"
      field :score, TP, type: "float"
      field :is_public, TP, type: "bool"
      field :owner_uuid, TP, type: "uuid"
      field :updated_at, TP, type: "datetime"
      field :dates, TP, type: "[]datetime"
      field :thumbnail, TP, type: "bytes"
      field :embedding, TP, type: "[3]f32", ann: [distance_metric: :cosine_distance]
      field :half_embedding, TP, type: "[2]f16", ann: true
      field :small_embedding, TP, type: "[2]i8", ann: true
      field :token_vectors, TP, type: "[][2]f32", ann: [late_interaction: true]
      field :sparse, TP, type: "{}f16", sparse_knn: [distance_metric: :dot_product]
    end
  end

  defmodule UuidDoc do
    use Ecto.Schema

    @primary_key {:id, TP, type: "uuid", autogenerate: false}
    schema "uuid_docs" do
      field :title, TP, type: "string"
    end
  end

  defmodule NestedDoc do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "nested_docs" do
      field :jurisdiction, :map
    end
  end

  defmodule EmbeddedVectorDoc do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embedded_vector_docs" do
      field :markdown, TP,
        type: "string",
        embed: [model: "openai/text-embedding-3-small", attribute: "markdown_vector", dims: 3]

      field :markdown_vector, TP, type: "[3]f32", ann: [distance_metric: :euclidean_squared]
    end
  end

  defmodule EmbedOnlyDoc do
    use Ecto.Schema
    use TP, distance_metric: :cosine_distance

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embed_only_docs" do
      field :markdown, TP, type: "string", full_text_search: true, embed: "openai/text-embedding-3-small"
    end
  end

  defmodule EmbedWithoutDistanceMetric do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embed_without_distance_metric" do
      field :markdown, TP, type: "string", embed: "openai/text-embedding-3-small"
    end
  end

  defmodule TooManyVectorColumns do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "too_many_vector_columns" do
      for i <- 1..7, do: field(:"vector_#{i}", TP, type: "[2]f32", ann: true)
      field :summary, TP, type: "string", embed: "openai/text-embedding-3-small"
      field :body, TP, type: "string", embed: "openai/text-embedding-3-small"
    end
  end

  defmodule TooManyEmbeds do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "too_many_embeds" do
      for i <- 1..5, do: field(:"text_#{i}", TP, type: "string", embed: "openai/text-embedding-3-small")
    end
  end

  defmodule TooManyAttributes do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "too_many_attributes" do
      for i <- 1..1024, do: field(:"attribute_#{i}", TP, type: "int")
    end
  end

  defmodule MixedDistanceMetrics do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "mixed_distance_metrics" do
      field :a, TP, type: "[2]f32", ann: [distance_metric: :cosine_distance]
      field :b, TP, type: "[2]f32", ann: [distance_metric: :euclidean_squared]
    end
  end

  defmodule WithoutId do
    use Ecto.Schema

    @primary_key false
    schema "without_id" do
      field :title, TP, type: "string"
    end
  end

  defmodule InvalidNamespaceName do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "card stacks/v1" do
      field :title, TP, type: "string"
    end
  end

  defmodule MissingEmbedTarget do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "missing_embed_target" do
      field :markdown, TP, type: "string", embed: [model: "openai/text-embedding-3-small", attribute: "vec"]
    end
  end

  defmodule MismatchedEmbedTarget do
    use Ecto.Schema

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "mismatched_embed_target" do
      field :markdown, TP,
        type: "string",
        embed: [model: "openai/text-embedding-3-small", attribute: "vec", dims: 4, dtype: :f16]

      field :vec, TP, type: "[3]f32", ann: true
    end
  end

  defp full_doc do
    %Doc{
      id: "5f1b2c3d4e5f6a7b8c9d0e1f",
      title: "Fractions on a number line",
      markdown: "# Fractions\n\nPlace 1/2 on the line.",
      notation: "3.NF.A.2",
      planbook_id: "planbook-1",
      standard_ids: ["s1", "s2"],
      position: -3,
      views: 12,
      score: 0.5,
      is_public: false,
      owner_uuid: "769c134d-07b8-4225-954a-b6cc5ffc320c",
      updated_at: ~U[2026-09-24 12:34:56.123Z],
      dates: [~U[2026-09-01 00:00:00.000Z]],
      thumbnail: <<0, 1, 255>>,
      embedding: [0.25, -0.5, 1.0],
      half_embedding: [0.5, -2.0],
      small_embedding: [-128, 127],
      token_vectors: [[0.5, 0.25], [1.0, -1.0]],
      sparse: %{"fraction" => 0.5}
    }
  end

  defp f32_base64(values), do: Base.encode64(for v <- values, into: <<>>, do: <<v::float-32-little>>)

  describe "schema/1" do
    test "renders every attribute's turbopuffer schema under its source name" do
      assert TP.schema(Doc) == %{
               "title" => %{
                 "type" => "string",
                 "full_text_search" => %{"language" => "english", "stemming" => true}
               },
               "markdown" => %{
                 "type" => "string",
                 "full_text_search" => true,
                 "embed" => "openai/text-embedding-3-small"
               },
               "notation" => %{"type" => "string", "glob" => true, "filterable" => true},
               "planbookId" => %{"type" => "string"},
               "standard_ids" => %{"type" => "[]string"},
               "position" => %{"type" => "int"},
               "views" => %{"type" => "uint"},
               "score" => %{"type" => "float"},
               "is_public" => %{"type" => "bool"},
               "owner_uuid" => %{"type" => "uuid"},
               "updated_at" => %{"type" => "datetime"},
               "dates" => %{"type" => "[]datetime"},
               "thumbnail" => %{"type" => "bytes"},
               "embedding" => %{"type" => "[3]f32", "ann" => %{"distance_metric" => "cosine_distance"}},
               "half_embedding" => %{"type" => "[2]f16", "ann" => true},
               "small_embedding" => %{"type" => "[2]i8", "ann" => true},
               "token_vectors" => %{"type" => "[][2]f32", "ann" => %{"late_interaction" => true}},
               "sparse" => %{"type" => "{}f16", "sparse_knn" => %{"distance_metric" => "dot_product"}}
             }
    end

    test "declares non-string ids" do
      assert TP.schema(UuidDoc) == %{"id" => "uuid", "title" => %{"type" => "string"}}
    end

    test "accepts an embed that writes into a declared vector" do
      assert TP.schema(EmbeddedVectorDoc)["markdown"]["embed"]["attribute"] == "markdown_vector"
    end

    test "refuses fields that aren't TP" do
      assert_raise ArgumentError, ~r/TPTest.NestedDoc.jurisdiction .* flatten embedded data into TP fields/, fn ->
        TP.schema(NestedDoc)
      end
    end

    for {module, message} <- [
          {WithoutId, ~r/TPTest.WithoutId needs one TP primary key/},
          {InvalidNamespaceName, ~r/namespace "card stacks\/v1" must match turbopuffer's \[A-Za-z0-9-_.\]\{1,128\}/},
          {TooManyVectorColumns, ~r/has 9 vector columns, counting embedded attributes' computed vectors/},
          {TooManyEmbeds, ~r/embeds 5 attributes; turbopuffer allows 4/},
          {TooManyAttributes, ~r/has 1025 attributes; turbopuffer allows 1024/},
          {MixedDistanceMetrics, ~r/different distance metrics \(cosine_distance, euclidean_squared\)/},
          {EmbedWithoutDistanceMetric,
           ~r/has vector columns, so turbopuffer needs a distance metric: add `use TP, distance_metric:/},
          {MissingEmbedTarget, ~r/embed attribute "vec" must be an \[N\] vector field in the schema/},
          {MismatchedEmbedTarget, ~r/embed dims 4 don't match vec's 3 dimensions/}
        ] do
      test "enforces namespace limits: #{inspect(module)}" do
        assert_raise ArgumentError, unquote(Macro.escape(message)), fn -> TP.schema(unquote(module)) end
      end
    end
  end

  describe "distance_metric/1" do
    test "comes from `use TP` or a vector's ann options" do
      assert TP.distance_metric(EmbedOnlyDoc) == "cosine_distance"
      assert TP.distance_metric(Doc) == "cosine_distance"
      assert TP.distance_metric(EmbeddedVectorDoc) == "euclidean_squared"
    end

    test "is nil without vector columns" do
      assert TP.distance_metric(UuidDoc) == nil
    end
  end

  describe "use TP" do
    defp compile(fields, use_opts) do
      Code.compile_string("""
      defmodule TPTest.Compiled#{System.unique_integer([:positive])} do
        use Ecto.Schema
        use TP, #{use_opts}

        @primary_key {:id, TP, type: "string", autogenerate: false}
        schema "compiled" do
          #{fields}
        end
      end
      """)
    end

    test "accepts a distance metric matching the vectors'" do
      assert [{module, _}] =
               compile(
                 ~s(field :vec, TP, type: "[2]f32", ann: [distance_metric: :cosine_distance]),
                 "distance_metric: :cosine_distance"
               )

      assert TP.distance_metric(module) == "cosine_distance"
    end

    for {description, fields, use_opts, message} <- [
          {"unknown options", ~s(field :title, TP, type: "string"), "distance: :cosine_distance",
           ~r/unknown `use TP` option\(s\) \[:distance\]/},
          {"unknown distance metrics", ~s(field :title, TP, type: "string"), "distance_metric: :manhattan",
           ~r/:distance_metric must be one of cosine_distance, euclidean_squared, got: :manhattan/},
          {"a metric the vectors contradict",
           ~s(field :vec, TP, type: "[2]f32", ann: [distance_metric: :cosine_distance]),
           "distance_metric: :euclidean_squared",
           ~r/different distance metrics \(euclidean_squared, cosine_distance\)/},
          {"namespace limits", ~S[for i <- 1..5, do: field(:"t#{i}", TP, type: "string", embed: "m")],
           "distance_metric: :cosine_distance", ~r/embeds 5 attributes; turbopuffer allows 4/},
          {"fields that aren't TP", ~s(field :jurisdiction, :map), "distance_metric: :cosine_distance",
           ~r/flatten embedded data into TP fields/}
        ] do
      test "rejects #{description} at compile time" do
        assert_raise ArgumentError, unquote(Macro.escape(message)), fn ->
          compile(unquote(fields), unquote(use_opts))
        end
      end
    end
  end

  describe "dump/1" do
    test "encodes each value the way turbopuffer's API expects" do
      assert TP.dump(full_doc()) == %{
               "id" => "5f1b2c3d4e5f6a7b8c9d0e1f",
               "title" => "Fractions on a number line",
               "markdown" => "# Fractions\n\nPlace 1/2 on the line.",
               "notation" => "3.NF.A.2",
               "planbookId" => "planbook-1",
               "standard_ids" => ["s1", "s2"],
               "position" => -3,
               "views" => 12,
               "score" => 0.5,
               "is_public" => false,
               "owner_uuid" => "769c134d-07b8-4225-954a-b6cc5ffc320c",
               "updated_at" => "2026-09-24T12:34:56.123Z",
               "dates" => ["2026-09-01T00:00:00.000Z"],
               "thumbnail" => "AAH/",
               "embedding" => f32_base64([0.25, -0.5, 1.0]),
               "half_embedding" => f32_base64([0.5, -2.0]),
               "small_embedding" => f32_base64([-128, 127]),
               "token_vectors" => [[0.5, 0.25], [1.0, -1.0]],
               "sparse" => %{"fraction" => 0.5}
             }
    end

    test "normalizes loose Elixir values" do
      row =
        TP.dump(%{
          full_doc()
          | title: nil,
            score: 2,
            owner_uuid: "769C134D-07B8-4225-954A-B6CC5FFC320C",
            updated_at: ~U[2026-09-24 08:00:00.123456Z],
            dates: [~D[2026-09-24], ~N[2026-09-24 08:00:00]],
            embedding: [1, 0, -1],
            sparse: %{fraction: 1}
        })

      assert row["title"] == nil
      assert row["score"] == 2.0
      assert row["owner_uuid"] == "769c134d-07b8-4225-954a-b6cc5ffc320c"
      assert row["updated_at"] == "2026-09-24T08:00:00.123Z"
      assert row["dates"] == ["2026-09-24T00:00:00.000Z", "2026-09-24T08:00:00.000Z"]
      assert row["embedding"] == f32_base64([1.0, 0.0, -1.0])
      assert row["sparse"] == %{"fraction" => 1.0}
    end

    test "raises without an id" do
      assert_raise ArgumentError, ~r/cannot dump TPTest.Doc without an id/, fn ->
        TP.dump(%{full_doc() | id: nil})
      end
    end

    test "raises without a vector" do
      assert_raise ArgumentError, ~r/without :embedding: turbopuffer upserts must include every vector attribute/, fn ->
        TP.dump(%{full_doc() | embedding: nil})
      end
    end

    test "lets native embedding fill a vector from its string" do
      assert TP.dump(%EmbeddedVectorDoc{id: "doc", markdown: "# Fractions"}) == %{
               "id" => "doc",
               "markdown" => "# Fractions"
             }

      assert TP.dump(%EmbeddedVectorDoc{id: "doc", markdown: "# Fractions", markdown_vector: [1, 0, 0]}) ==
               %{"id" => "doc", "markdown" => "# Fractions", "markdown_vector" => f32_base64([1.0, 0.0, 0.0])}

      assert_raise ArgumentError, ~r/without :markdown_vector/, fn ->
        TP.dump(%EmbeddedVectorDoc{id: "doc"})
      end
    end

    test "enforces turbopuffer's value limits" do
      big = String.duplicate("a", 4_097)

      for {field, value, message} <- [
            {:id, String.duplicate("a", 65), ~r/ids can be at most 64 bytes/},
            {:planbook_id, big, ~r/4097 bytes, over turbopuffer's 4 KiB limit for filterable values/},
            {:notation, big, ~r/4 KiB limit for filterable values/},
            {:standard_ids, ["s1", big], ~r/4 KiB limit for filterable values/},
            {:thumbnail, :binary.copy(<<0>>, 8 * 1024 * 1024 + 1), ~r/over turbopuffer's 8 MiB limit per value/},
            {:sparse, Map.new(1..1_025, &{"d#{&1}", 1.0}), ~r/sparse vectors can have at most 1024 dimensions/}
          ] do
        assert_raise ArgumentError, message, fn -> TP.dump(Map.put(full_doc(), field, value)) end
      end

      assert TP.dump(%{full_doc() | title: big, markdown: big})["title"] == big
    end

    for {field, value} <- [
          embedding: [1.0, 2.0],
          embedding: [1.0e39, 0, 0],
          half_embedding: [70_000.0, 0],
          small_embedding: [128, 0],
          small_embedding: [1.5, 0],
          token_vectors: [[1.0]],
          standard_ids: ["s1", nil],
          position: 9_223_372_036_854_775_808,
          views: -1,
          owner_uuid: "not-a-uuid",
          updated_at: "yesterday",
          is_public: "maybe",
          sparse: %{"fraction" => "high"},
          title: 42
        ] do
      test "raises when #{field} is #{inspect(value)}" do
        doc = Map.put(full_doc(), unquote(field), unquote(Macro.escape(value)))

        assert_raise ArgumentError, ~r/cannot dump .* for field :#{unquote(field)} in TPTest.Doc/, fn ->
          TP.dump(doc)
        end
      end
    end
  end

  describe "dump_attribute/3" do
    test "encodes filter operands like the attribute's values" do
      assert TP.dump_attribute(Doc, :updated_at, ~U[2026-09-24 12:34:56.123456Z]) == "2026-09-24T12:34:56.123Z"

      assert TP.dump_attribute(Doc, :owner_uuid, "769C134D-07B8-4225-954A-B6CC5FFC320C") ==
               "769c134d-07b8-4225-954a-b6cc5ffc320c"

      assert TP.dump_attribute(Doc, :standard_ids, ["s1"]) == ["s1"]
      assert TP.dump_attribute(Doc, :title, nil) == nil
    end

    test "raises on unknown fields and bad values" do
      assert_raise ArgumentError, ~r/TPTest.Doc has no field :nope/, fn -> TP.dump_attribute(Doc, :nope, 1) end

      assert_raise ArgumentError, ~r/4 KiB limit for filterable values/, fn ->
        TP.dump_attribute(Doc, :planbook_id, String.duplicate("a", 4_097))
      end
    end
  end

  describe "load/2" do
    test "decodes turbopuffer's response encodings and ignores undeclared attributes" do
      loaded =
        TP.load(Doc, %{
          "id" => "doc",
          "$dist" => 0.12,
          "updated_at" => "2026-09-24T12:34:56.123000000Z",
          "dates" => ["2026-01-02T03:04:05.000000000Z"],
          "thumbnail" => "AAH/",
          "embedding" => f32_base64([0.25, -0.5, 1.0]),
          "half_embedding" => "ADgAPQ==",
          "small_embedding" => "/Qc="
        })

      assert loaded.id == "doc"
      assert loaded.updated_at == ~U[2026-09-24 12:34:56.123Z]
      assert loaded.dates == [~U[2026-01-02 03:04:05.000Z]]
      assert loaded.thumbnail == <<0, 1, 255>>
      assert loaded.embedding == [0.25, -0.5, 1.0]
      assert loaded.half_embedding == [0.5, 1.25]
      assert loaded.small_embedding == [-3, 7]
      assert loaded.title == nil

      assert TP.load(Doc, %{"id" => "doc", "small_embedding" => [-128.0, 127.0]}).small_embedding == [-128, 127]
    end

    test "raises on values that don't fit the schema" do
      assert_raise ArgumentError, ~r/cannot load "not base64!" as turbopuffer bytes for field :thumbnail/, fn ->
        TP.load(Doc, %{"id" => "doc", "thumbnail" => "not base64!"})
      end
    end
  end

  describe "Ecto integration" do
    test "changesets cast through the turbopuffer type" do
      changeset =
        Ecto.Changeset.cast(
          %Doc{},
          %{"position" => "7", "updated_at" => "2026-09-24", "embedding" => [1, 2, 3], "standard_ids" => ["a"]},
          [:position, :updated_at, :embedding, :standard_ids]
        )

      assert changeset.valid?

      assert changeset.changes == %{
               position: 7,
               updated_at: ~U[2026-09-24 00:00:00.000Z],
               embedding: [1.0, 2.0, 3.0],
               standard_ids: ["a"]
             }

      refute Ecto.Changeset.cast(%Doc{}, %{"embedding" => [1, 2]}, [:embedding]).valid?
    end

    test "Ecto's dump enforces the same limits" do
      type = Doc.__schema__(:type, :planbook_id)
      assert Ecto.Type.dump(type, "planbook-1") == {:ok, "planbook-1"}
      assert Ecto.Type.dump(type, String.duplicate("a", 4_097)) == :error
    end

    test "formats the type with its turbopuffer type string" do
      assert Ecto.Type.format(Doc.__schema__(:type, :standard_ids)) == "#TP<[]string>"
    end
  end
end
