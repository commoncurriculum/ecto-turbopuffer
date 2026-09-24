defmodule Ecto.Adapters.Turbopuffer.TypesTest do
  use TP.Test.Case, async: true

  alias TP.Test.Everything

  defp everything do
    %Everything{
      id: "doc",
      title: "Photosynthesis in plants",
      planbook_id: "planbook-1",
      position: -3,
      views: 18_446_744_073_709_551_615,
      score: 1.5,
      is_public: true,
      owner_uuid: "769c134d-07b8-4225-954a-b6cc5ffc320c",
      updated_at: ~U[2026-09-24 12:34:56.123Z],
      thumbnail: <<0, 1, 255>>,
      tags: ["biology", "grade 5"],
      positions: [-1, 0, 1],
      counts: [0, 7],
      scores: [0.5, -2.25],
      flags: [true, false],
      owner_uuids: ["769c134d-07b8-4225-954a-b6cc5ffc320c"],
      dates: [~U[2026-01-02 03:04:05.000Z], ~U[2026-01-03 00:00:00.000Z]],
      embedding: [0.25, -0.5, 1.0],
      half_embedding: [0.5, 1.25],
      small_embedding: [-128, 127],
      sparse: %{"1" => 0.5, "7" => 1.0}
    }
  end

  test "every type round-trips through turbopuffer" do
    Repo.insert!(everything())

    loaded = Repo.get!(Everything, "doc")

    for field <- Everything.__schema__(:fields) do
      assert Map.fetch!(loaded, field) == Map.fetch!(everything(), field), "#{field} didn't round-trip"
    end
  end

  test "turbopuffer stores the schema TP declares", %{prefix: prefix} do
    Repo.insert!(everything())

    {:ok, %{"schema" => stored}} =
      Repo
      |> Ecto.Adapters.Turbopuffer.client()
      |> Ecto.Adapters.Turbopuffer.Request.metadata(Ecto.Adapters.Turbopuffer.namespace(Everything, prefix))

    for attribute <- TP.__attributes__(Everything) do
      stored_entry = Map.fetch!(stored, attribute.name)

      assert stored_entry["type"] == TP.Types.encode(attribute.type), "#{attribute.name}'s type"

      if Map.has_key?(stored_entry, "filterable") do
        assert stored_entry["filterable"] == attribute.filterable, "whether #{attribute.name} is filterable"
      end

      for {option, value} <- Map.delete(attribute.schema_entry, "type") do
        assert_stored(stored_entry[option], value, "#{attribute.name}'s #{option}")
      end
    end
  end

  # turbopuffer echoes `true` settings back as their full configuration, e.g. every BM25 parameter.
  defp assert_stored(stored, true, label), do: assert(stored not in [nil, false], label)

  defp assert_stored(stored, %{} = declared, label) do
    for {key, value} <- declared, do: assert(stored[key] == value, "#{label}.#{key}")
  end

  defp assert_stored(stored, declared, label), do: assert(stored == declared, label)

  test "a namespace that doesn't exist yet reads as empty" do
    assert Repo.all(Everything) == []
    assert Repo.get(Everything, "doc") == nil
    assert Repo.aggregate(Everything, :count) == 0
  end
end
