defmodule TP.Test.Everything do
  @moduledoc "Every turbopuffer type the API generally offers. Multi-vectors are in private beta, so they're left out."
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "everything" do
    field :title, TP, type: "string", full_text_search: [language: :english, stemming: true], regex: true
    field :planbook_id, TP, type: "string", source: :planbookId
    field :position, TP, type: "int"
    field :views, TP, type: "uint"
    field :score, TP, type: "float"
    field :is_public, TP, type: "bool"
    field :owner_uuid, TP, type: "uuid"
    field :updated_at, TP, type: "datetime"
    field :thumbnail, TP, type: "bytes"
    field :tags, TP, type: "[]string", glob: true, fuzzy: true
    field :positions, TP, type: "[]int"
    field :counts, TP, type: "[]uint"
    field :scores, TP, type: "[]float"
    field :flags, TP, type: "[]bool"
    field :owner_uuids, TP, type: "[]uuid"
    field :dates, TP, type: "[]datetime"
    field :embedding, TP, type: "[3]f32", ann: true
    field :half_embedding, TP, type: "[2]f16", ann: true
    field :small_embedding, TP, type: "[2]i8", ann: true
    field :sparse, TP, type: "{}f16", sparse_knn: [distance_metric: :dot_product]
  end
end

defmodule TP.Test.CardStack do
  @moduledoc false
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "card_stacks" do
    field :title, TP, type: "string", full_text_search: true, glob: true, fuzzy: true, filterable: true
    field :markdown, TP, type: "string", full_text_search: true
    field :planbook_id, TP, type: "string"
    field :standard_ids, TP, type: "[]string"
    field :position, TP, type: "int"
    field :vector, TP, type: "[3]f32", ann: true
  end
end

defmodule TP.Test.ReviewedCardStack do
  @moduledoc "CardStack's namespace, with an attribute its documents don't have yet."
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "card_stacks" do
    field :vector, TP, type: "[3]f32", ann: true
    field :reviewed_at, TP, type: "datetime"
  end
end

defmodule TP.Test.Lesson do
  @moduledoc false
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "uuid", autogenerate: true}
  schema "lessons" do
    field :markdown, TP, type: "string", filterable: false, embed: "openai/text-embedding-3-small"
  end
end
