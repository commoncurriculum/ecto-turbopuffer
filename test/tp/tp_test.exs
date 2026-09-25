defmodule TPTest do
  use ExUnit.Case, async: true

  defmodule Doc do
    use Ecto.Schema
    use TP, distance_metric: :cosine_distance

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "docs" do
      field :title, TP, type: "string", full_text_search: [language: :english, stemming: true]
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
      field :embedding, TP, type: "[3]f32", ann: true
      field :half_embedding, TP, type: "[2]f16", ann: true
      field :small_embedding, TP, type: "[2]i8", ann: true
      field :token_vectors, TP, type: "[][2]f32", ann: [late_interaction: true]
      field :sparse, TP, type: "{}f16", sparse_knn: [distance_metric: :dot_product]
    end
  end

  defp type(field), do: Doc.__schema__(:type, field)
  defp cast(field, value), do: Ecto.Type.cast(type(field), value)
  defp dump(field, value), do: Ecto.Type.dump(type(field), value)
  defp load(field, value), do: Ecto.Type.load(type(field), value)

  defp f32_base64(values), do: Base.encode64(for v <- values, into: <<>>, do: <<v::float-32-little>>)

  describe "use TP" do
    defp compile(body) do
      Code.compile_string("""
      defmodule TPTest.Compiled#{System.unique_integer([:positive])} do
        #{body}
      end
      """)
    end

    test "is required on schemas with TP fields" do
      assert_raise ArgumentError, ~r/has TP fields, so it needs `use TP` before `schema`/, fn ->
        compile("""
        use Ecto.Schema

        @primary_key {:id, TP, type: "string", autogenerate: false}
        schema "docs" do
          field :title, TP, type: "string"
        end
        """)
      end
    end

    test "sets the namespace's distance metric" do
      [{module, _}] =
        compile("""
        use Ecto.Schema
        use TP, distance_metric: :euclidean_squared

        @primary_key {:id, TP, type: "string", autogenerate: false}
        schema "docs" do
          field :vector, TP, type: "[2]f32", ann: true
        end
        """)

      assert module.__tp__(:distance_metric) == "euclidean_squared"
    end

    test "rejects unknown options and distance metrics" do
      assert_raise ArgumentError, ~r/unknown keys \[:distance\]/, fn ->
        compile("use Ecto.Schema\nuse TP, distance: :cosine_distance")
      end

      assert_raise ArgumentError, ~r/:distance_metric must be :cosine_distance or :euclidean_squared, got: :dot/, fn ->
        compile("use Ecto.Schema\nuse TP, distance_metric: :dot")
      end
    end
  end

  describe "cast" do
    test "takes loose values the way Ecto's types do" do
      assert cast(:position, "7") == {:ok, 7}
      assert cast(:score, 2) == {:ok, 2.0}
      assert cast(:owner_uuid, "769C134D-07B8-4225-954A-B6CC5FFC320C") == {:ok, "769c134d-07b8-4225-954a-b6cc5ffc320c"}
      assert cast(:updated_at, "2026-09-24") == {:ok, ~U[2026-09-24 00:00:00.000Z]}
      assert cast(:updated_at, ~U[2026-09-24 08:00:00.123456Z]) == {:ok, ~U[2026-09-24 08:00:00.123Z]}

      assert cast(:dates, [~D[2026-09-24], ~N[2026-09-24 08:00:00]]) ==
               {:ok, [~U[2026-09-24 00:00:00.000Z], ~U[2026-09-24 08:00:00.000Z]]}

      assert cast(:embedding, [1, 0, -1]) == {:ok, [1.0, 0.0, -1.0]}
      assert cast(:sparse, %{fraction: 1}) == {:ok, %{"fraction" => 1.0}}
      assert cast(:title, nil) == {:ok, nil}
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
          sparse: %{"fraction" => 70_000.0},
          title: 42
        ] do
      test "rejects #{inspect(value)} for #{field}" do
        assert cast(unquote(field), unquote(Macro.escape(value))) == :error
      end
    end
  end

  describe "dump" do
    test "encodes each value the way turbopuffer's API expects" do
      for {field, value, dumped} <- [
            {:id, "5f1b2c3d4e5f6a7b8c9d0e1f", "5f1b2c3d4e5f6a7b8c9d0e1f"},
            {:title, "Fractions", "Fractions"},
            {:standard_ids, ["s1", "s2"], ["s1", "s2"]},
            {:position, -3, -3},
            {:views, 18_446_744_073_709_551_615, 18_446_744_073_709_551_615},
            {:score, 0.5, 0.5},
            {:is_public, false, false},
            {:owner_uuid, "769c134d-07b8-4225-954a-b6cc5ffc320c", "769c134d-07b8-4225-954a-b6cc5ffc320c"},
            {:updated_at, ~U[2026-09-24 12:34:56.123456Z], "2026-09-24T12:34:56.123Z"},
            {:dates, [~U[2026-09-01 00:00:00.000Z]], ["2026-09-01T00:00:00.000Z"]},
            {:thumbnail, <<0, 1, 255>>, "AAH/"},
            {:embedding, [0.25, -0.5, 1.0], f32_base64([0.25, -0.5, 1.0])},
            {:embedding, [1, 0, -1], f32_base64([1.0, 0.0, -1.0])},
            {:half_embedding, [0.5, -2.0], f32_base64([0.5, -2.0])},
            {:small_embedding, [-128, 127], f32_base64([-128, 127])},
            {:token_vectors, [[0.5, 0.25], [1.0, -1.0]], [[0.5, 0.25], [1.0, -1.0]]},
            {:sparse, %{"fraction" => 0.5}, %{"fraction" => 0.5}},
            {:title, nil, nil}
          ] do
        assert dump(field, value) == {:ok, dumped}, "#{field}: #{inspect(value)}"
      end
    end

    test "only encodes values that already fit the type" do
      for {field, value} <- [
            position: "7",
            views: -1,
            owner_uuid: "769C134D-07B8-4225-954A-B6CC5FFC320C",
            updated_at: ~N[2026-09-24 08:00:00],
            updated_at: "2026-09-24",
            dates: [~U[2026-09-01 00:00:00Z], nil],
            half_embedding: [70_000.0, 0],
            sparse: %{fraction: 1.0},
            sparse: %{"fraction" => 70_000.0},
            title: 42
          ] do
        assert dump(field, value) == :error, "#{field}: #{inspect(value)}"
      end
    end

    test "leaves write limits to writes, so filters can compare against any value" do
      assert dump(:id, String.duplicate("a", 65)) == {:ok, String.duplicate("a", 65)}
      assert dump(:planbook_id, String.duplicate("a", 4_097)) == {:ok, String.duplicate("a", 4_097)}
    end
  end

  describe "load" do
    test "decodes turbopuffer's response encodings" do
      for {field, value, loaded} <- [
            {:updated_at, "2026-09-24T12:34:56.123000000Z", ~U[2026-09-24 12:34:56.123Z]},
            {:dates, ["2026-01-02T03:04:05.000000000Z"], [~U[2026-01-02 03:04:05.000Z]]},
            {:thumbnail, "AAH/", <<0, 1, 255>>},
            {:embedding, f32_base64([0.25, -0.5, 1.0]), [0.25, -0.5, 1.0]},
            {:embedding, [0.25, -0.5, 1.0], [0.25, -0.5, 1.0]},
            {:half_embedding, "ADgAPQ==", [0.5, 1.25]},
            {:small_embedding, "/Qc=", [-3, 7]},
            {:small_embedding, [-128.0, 127.0], [-128, 127]},
            {:token_vectors, [[0.5, 0.25]], [[0.5, 0.25]]},
            {:sparse, %{"fraction" => 0.5}, %{"fraction" => 0.5}},
            {:title, nil, nil}
          ] do
        assert load(field, value) == {:ok, loaded}, "#{field}: #{inspect(value)}"
      end
    end

    test "rejects values that don't fit the schema" do
      assert load(:thumbnail, "not base64!") == :error
      assert load(:embedding, f32_base64([1.0, 2.0])) == :error
    end
  end

  test "autogenerates uuids" do
    assert {:ok, _} = Ecto.UUID.cast(TP.autogenerate(TP.Attribute.new(type: "uuid", field: :id, primary_key: true)))
  end

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

  test "formats the type with its turbopuffer type string" do
    assert Ecto.Type.format(type(:standard_ids)) == "#TP<[]string>"
  end
end
