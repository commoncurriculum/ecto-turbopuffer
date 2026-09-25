defmodule TPTest do
  # How the TP type casts, encodes and decodes values, without turbopuffer. types_test.exs round-trips every type
  # through turbopuffer itself.
  use ExUnit.Case, async: true

  defmodule Doc do
    use Ecto.Schema
    use TP, distance_metric: :cosine_distance

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "docs" do
      field :title, TP, type: "string"
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

    test "sets the namespace's distance metric and shards" do
      [{module, _}] =
        compile("""
        use Ecto.Schema
        use TP, distance_metric: :euclidean_squared, num_shards: 4

        @primary_key {:id, TP, type: "string", autogenerate: false}
        schema "docs" do
          field :vector, TP, type: "[2]f32", ann: true
        end
        """)

      assert {module.__tp__(:distance_metric), module.__tp__(:num_shards)} == {"euclidean_squared", 4}
    end

    test "rejects unknown options, distance metrics and shard counts" do
      for {options, message} <- [
            {"distance: :cosine_distance", ~r/unknown keys \[:distance\]/},
            {"distance_metric: :dot", ~r/:distance_metric must be :cosine_distance or :euclidean_squared, got: :dot/},
            {"num_shards: 0", ~r/:num_shards must be an integer from 1 to 256, got: 0/},
            {"num_shards: 257", ~r/got: 257/}
          ] do
        assert_raise ArgumentError, message, fn -> compile("use Ecto.Schema\nuse TP, #{options}") end
      end
    end
  end

  test "casts loose values the way Ecto's types do" do
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

    changeset = Ecto.Changeset.cast(%Doc{}, %{"position" => "7", "embedding" => [1, 2, 3]}, [:position, :embedding])
    assert changeset.changes == %{position: 7, embedding: [1.0, 2.0, 3.0]}
    refute Ecto.Changeset.cast(%Doc{}, %{"embedding" => [1, 2]}, [:embedding]).valid?
  end

  test "casts nothing that doesn't fit the type" do
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
      assert cast(field, value) == :error, "#{field}: #{inspect(value)}"
    end
  end

  test "dumps only values that already fit the type, leaving write limits to writes" do
    for {field, value} <- [
          position: "7",
          views: -1,
          owner_uuid: "not-a-uuid",
          owner_uuid: <<0::128>>,
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

    # Filters compare against any value, like an id Repo.get is given.
    assert dump(:id, String.duplicate("a", 65)) == {:ok, String.duplicate("a", 65)}
  end

  test "loads turbopuffer's response encodings, and nothing that doesn't fit the type" do
    for {field, value, loaded} <- [
          {:updated_at, "2026-09-24T12:34:56.123000000Z", ~U[2026-09-24 12:34:56.123Z]},
          {:thumbnail, "AAH/", <<0, 1, 255>>},
          # base64 vectors come back in their own element type, as turbopuffer sent these.
          {:embedding, "AACAPgAAAL8AAIA/", [0.25, -0.5, 1.0]},
          {:half_embedding, "ADgAvQ==", [0.5, -1.25]},
          {:small_embedding, "gH8=", [-128, 127]},
          {:small_embedding, [-128.0, 127.0], [-128, 127]},
          {:token_vectors, [[0.5, 0.25]], [[0.5, 0.25]]}
        ] do
      assert load(field, value) == {:ok, loaded}, "#{field}: #{inspect(value)}"
    end

    for {field, value} <- [
          thumbnail: "not base64!",
          embedding: f32_base64([1.0, 2.0]),
          half_embedding: f32_base64([0.5, -1.25]),
          small_embedding: f32_base64([-128, 127]),
          half_embedding: [70_000.0, 0.0],
          small_embedding: [1.5, 0.0]
        ] do
      assert load(field, value) == :error, "#{field}: #{inspect(value)}"
    end
  end
end
