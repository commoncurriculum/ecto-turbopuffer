defmodule Ecto.Adapters.Turbopuffer.TypesTest do
  use TP.Test.Case, async: true

  alias TP.Test.{Everything, Lesson, MultiEmbed, ShardedStack, TextSettings}

  test "every type round-trips through turbopuffer, normalized the way turbopuffer stores it" do
    written =
      Everything.new(
        id: "doc",
        title: "Photosynthesis in plants",
        summary: "Résumé",
        tokens: ["self-evident"],
        planbook_id: "planbook-1",
        position: -3,
        views: 18_446_744_073_709_551_615,
        score: 1.5,
        is_public: true,
        owner_uuid: "769C134D-07B8-4225-954A-B6CC5FFC320C",
        updated_at: ~U[2026-09-24 12:34:56.123456Z],
        thumbnail: <<0, 1, 255>>,
        # Over the 4 KiB limit for filterable values, which a non-filterable attribute doesn't have.
        notes: String.duplicate("n", 5_000),
        tags: ["biology", "grade 5"],
        positions: [-1, 0, 1],
        counts: [0, 7],
        scores: [0.5, -2.25],
        flags: [true, false],
        owner_uuids: ["769c134d-07b8-4225-954a-b6cc5ffc320c"],
        dates: [~U[2026-01-02 03:04:05Z], ~U[2026-01-03 00:00:00.999999Z]],
        embedding: [1, -0.5, 0.25],
        half_embedding: [0.5, 1.25],
        small_embedding: [-128, 127],
        sparse: %{"1" => 0.5, "7" => 1.0}
      )

    Repo.insert!(written)

    expected = %{
      written
      | owner_uuid: "769c134d-07b8-4225-954a-b6cc5ffc320c",
        updated_at: ~U[2026-09-24 12:34:56.123Z],
        dates: [~U[2026-01-02 03:04:05.000Z], ~U[2026-01-03 00:00:00.999Z]],
        embedding: [1.0, -0.5, 0.25]
    }

    {loaded, [request]} = requests(fn -> Repo.get!(Everything, "doc") end)
    assert request.query["vector_encoding"] == "base64"

    for field <- Everything.__schema__(:fields) do
      assert Map.fetch!(loaded, field) == Map.fetch!(expected, field), "#{field} didn't round-trip"
    end
  end

  test "turbopuffer stores the schema TP declares, for every option" do
    Repo.insert!(Everything.new(id: "doc"))
    Repo.insert!(%Lesson{markdown: "Fractions."})
    Repo.insert!(%ShardedStack{id: 1})
    Repo.insert!(%MultiEmbed{id: "m", default: "a", quantized: "b", declared: "c", wide: "d"})
    Repo.insert!(%TextSettings{id: "t"})

    mismatches =
      for schema <- [Everything, Lesson, ShardedStack, MultiEmbed, TextSettings],
          stored = Turbopuffer.metadata(Repo, schema)["schema"],
          namespace = TP.Namespace.new(schema),
          attribute <- namespace.attributes,
          entry = Map.fetch!(stored, attribute.name),
          label = "#{inspect(schema)}.#{attribute.field}",
          mismatch <- attribute_mismatches(attribute, entry, namespace, label),
          do: mismatch

    assert mismatches == []
  end

  defp attribute_mismatches(attribute, entry, namespace, label) do
    # turbopuffer reports word_v0, its first tokenizer, by its original name.
    entry =
      if match?(%{"full_text_search" => %{"tokenizer" => "Word"}}, entry),
        do: put_in(entry, ["full_text_search", "tokenizer"], "word_v0"),
        else: entry

    options =
      for {option, declared} <- Map.delete(TP.Attribute.to_schema(attribute), "type") do
        # An embedding model given as a string comes back as its model and target attribute.
        stored = if option == "embed" and is_binary(declared), do: entry[option]["model"], else: entry[option]
        mismatches(stored, declared, "#{label}'s #{option}")
      end

    List.flatten([
      mismatches(entry["type"], TP.Types.encode(attribute.type), "#{label}'s type"),
      if(Map.has_key?(entry, "filterable") and not attribute.primary_key,
        do: mismatches(entry["filterable"], attribute.filterable, "whether #{label} is filterable"),
        else: []
      ),
      if(attribute.options[:ann],
        do: mismatches(entry["ann"]["distance_metric"], namespace.distance_metric, "#{label}'s distance metric"),
        else: []
      )
      | options
    ])
  end

  # turbopuffer echoes settings back as their full configuration: `true` as every BM25 parameter or an ANN index's
  # distance metric, and an embedding without dims and dtype, which show in the target's type instead.
  defp mismatches(stored, true, label), do: if(stored in [nil, false], do: ["#{label}: #{inspect(stored)}"], else: [])

  defp mismatches(stored, %{} = declared, label) do
    for {key, value} <- declared, key not in ["dims", "dtype"], do: mismatches(stored[key], value, "#{label}.#{key}")
  end

  defp mismatches(stored, declared, _label) when stored == declared, do: []
  defp mismatches(stored, declared, label), do: ["#{label}: stored #{inspect(stored)}, declared #{inspect(declared)}"]
end
