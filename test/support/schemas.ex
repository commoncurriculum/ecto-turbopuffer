defmodule TP.Test.Everything do
  @moduledoc """
  Every turbopuffer type the API generally offers, and every schema option but native embedding (see
  TP.Test.Embedding). Multi-vectors are in private beta, so they're left out.
  """
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "everything" do
    field :title, TP, type: "string", full_text_search: [language: :english, stemming: true], regex: true

    field :summary, TP,
      type: "string",
      filterable: true,
      full_text_search: [
        tokenizer: :word_v3,
        language: :french,
        stemming: false,
        remove_stopwords: true,
        case_sensitive: true,
        ascii_folding: true,
        max_token_length: 40,
        k1: 1.4,
        b: 0.6,
        k3: 7.5
      ]

    field :tokens, TP, type: "[]string", full_text_search: [tokenizer: :pre_tokenized_array]
    field :planbook_id, TP, type: "string", source: :planbookId
    field :position, TP, type: "int"
    field :views, TP, type: "uint"
    field :score, TP, type: "float"
    field :is_public, TP, type: "bool"
    field :owner_uuid, TP, type: "uuid"
    field :updated_at, TP, type: "datetime"
    field :thumbnail, TP, type: "bytes"
    field :notes, TP, type: "string", filterable: false
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

  @doc "A document with `attrs` and the vectors turbopuffer requires."
  def new(attrs) do
    struct(%__MODULE__{embedding: [1.0, 0.0, 0.0], half_embedding: [1.0, 0.0], small_embedding: [1, 0]}, attrs)
  end
end

defmodule TP.Test.TextSettings do
  @moduledoc "Every full-text search tokenizer and language (docs/turbopuffer/fts.md)."
  use Ecto.Schema
  use TP

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "text_settings" do
    for tokenizer <- ~w(word_v0 word_v1 word_v2 word_v3 word_v4)a do
      field tokenizer, TP, type: "string", full_text_search: [tokenizer: tokenizer]
    end

    # Stopword removal isn't supported for arabic, greek, romanian, tamil, and turkish.
    for language <- ~w(arabic danish dutch english finnish french german greek hungarian italian norwegian portuguese
                       romanian russian spanish swedish tamil turkish)a do
      stopwords = language not in ~w(arabic greek romanian tamil turkish)a

      field language, TP,
        type: "string",
        full_text_search: [language: language, stemming: true, remove_stopwords: stopwords]
    end
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

defmodule TP.Test.ShardedStack do
  @moduledoc false
  use Ecto.Schema
  use TP, num_shards: 2

  @primary_key {:id, TP, type: "uint", autogenerate: false}
  schema "sharded_stacks" do
    field :position, TP, type: "int"
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

defmodule TP.Test.Note do
  @moduledoc "Notes with vectors computed elsewhere, before native embedding."
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "notes" do
    field :text, TP, type: "string"
    field :vector, TP, type: "[256]f32", ann: true
  end
end

defmodule TP.Test.EmbeddedNote do
  @moduledoc "Note's namespace, once turbopuffer embeds its text into the same vectors."
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "notes" do
    field :text, TP, type: "string", embed: [model: "openai/text-embedding-3-small", attribute: "vector"]
    field :vector, TP, type: "[256]f32", ann: true
  end
end

defmodule TP.Test.MultiEmbed do
  @moduledoc "turbopuffer's limit of 4 embedded attributes, each embedded a different way."
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "multi_embeds" do
    field :default, TP, type: "string", embed: "openai/text-embedding-3-small"
    field :quantized, TP, type: "string", embed: [model: "voyage/voyage-4-lite", dims: 256, dtype: :i8]
    field :declared, TP, type: "string", embed: [model: "cohere/embed-v4.0", attribute: "declared_vector"]
    field :declared_vector, TP, type: "[512]f16", ann: true
    field :wide, TP, type: "string", embed: [model: "baai/bge-m3", dtype: :f32]
  end
end

defmodule TP.Test.Embedding do
  @moduledoc """
  turbopuffer's embedding models, as it reported them in gcp-us-central1: each model's default dimensions, the
  dimensions it supports, and whether it can embed i8. Every model's default element type is f16, and all of them
  can embed f16 and f32.

  Each model has a schema that embeds `text` with its defaults (`default/1`), and one per dimensions and element
  type that embeds `text` into a declared `vector` (`schema/3`), for those it supports and two it doesn't: 7
  dimensions, and i8 for models that can't embed it.
  """

  @models [
    {"baai/bge-m3", 1024, [1024], false},
    {"cohere/embed-v4.0", 1536, [256, 512, 1024, 1536], false},
    {"google/gemini-embedding-2", 1536, [768, 1536, 3072], false},
    {"nvidia/nemotron-3-embed-1b", 2048, [512, 1024, 2048], false},
    {"nvidia/nemotron-3-embed-8b", 4096, [512, 1024, 2048, 4096], false},
    {"openai/text-embedding-3-large", 3072, [256, 512, 1024, 1536, 3072], false},
    {"openai/text-embedding-3-small", 1536, [256, 512, 768, 1024, 1536], false},
    {"openai/text-embedding-ada-002", 1536, [1536], false},
    {"qwen/qwen3-embedding-0p6b", 1024, [256, 384, 512, 768, 1024], false},
    {"qwen/qwen3-embedding-4b", 1024, [512, 1024, 1536, 2048, 2560], false},
    {"qwen/qwen3-embedding-8b", 1024, [512, 1024, 1536, 2048, 3072, 4096], false},
    {"voyage/voyage-4", 1024, [256, 512, 1024, 2048], true},
    {"voyage/voyage-4-large", 1024, [256, 512, 1024, 2048], true},
    {"voyage/voyage-4-lite", 1024, [256, 512, 1024, 2048], true},
    {"voyage/voyage-4-nano", 1024, [256, 512, 1024, 2048], false},
    {"voyage/voyage-code-3", 1024, [256, 512, 1024, 2048], true},
    {"voyage/voyage-code-4", 1024, [256, 512, 1024, 2048], true},
    {"zeroentropy/zembed-1", 1280, [40, 80, 160, 320, 640, 1280, 2560], false}
  ]

  @doc "`{model, default_dims, supported_dims, i8?}` for each model."
  def models, do: @models

  @doc "The element types a model can embed."
  def dtypes(i8?), do: if(i8?, do: [:f32, :f16, :i8], else: [:f32, :f16])

  @doc "The schemas a model has for dimensions and element types it doesn't support."
  def unsupported({_model, _default, supported, i8?}), do: [{7, :f32} | if(i8?, do: [], else: [{hd(supported), :i8}])]

  @doc "The model's schema that embeds `text` with its defaults."
  def default(model), do: Module.concat(namespace(model), Default)

  @doc "The model's schema that embeds `text` into a declared `[dims]dtype` vector."
  def schema(model, dims, dtype), do: Module.concat(namespace(model), "D#{dims}#{String.upcase(to_string(dtype))}")

  @doc "A model's name as an identifier, like `voyage_voyage_4_lite`."
  def slug(model), do: String.replace(model, ~r/[^a-z0-9]+/, "_")

  defp namespace(model), do: Module.concat(__MODULE__, Macro.camelize(slug(model)))
end

for {model, _default, supported, i8?} = entry <- TP.Test.Embedding.models() do
  slug = TP.Test.Embedding.slug(model)

  defmodule TP.Test.Embedding.default(model) do
    @moduledoc false
    use Ecto.Schema
    use TP, distance_metric: :cosine_distance

    @primary_key {:id, TP, type: "string", autogenerate: false}
    schema "embed_#{slug}" do
      field :text, TP, type: "string", embed: model
    end
  end

  shapes = for(dims <- supported, dtype <- TP.Test.Embedding.dtypes(i8?), do: {dims, dtype})

  for {dims, dtype} <- shapes ++ TP.Test.Embedding.unsupported(entry) do
    defmodule TP.Test.Embedding.schema(model, dims, dtype) do
      @moduledoc false
      use Ecto.Schema
      use TP, distance_metric: :cosine_distance

      @primary_key {:id, TP, type: "string", autogenerate: false}
      schema "embed_#{slug}_#{dims}_#{dtype}" do
        field :text, TP, type: "string", embed: [model: model, attribute: "vector", dims: dims, dtype: dtype]
        field :vector, TP, type: "[#{dims}]#{dtype}", ann: true
      end
    end
  end
end
