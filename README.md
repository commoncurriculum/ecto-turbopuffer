# ecto_turbopuffer

An Ecto adapter and types for [turbopuffer](https://turbopuffer.com): define a namespace as an Ecto schema, write
to it with `Repo.insert`, and search it with `Ecto.Query`.

```elixir
defmodule MyApp.Search.CardStack do
  use Ecto.Schema
  use TP, distance_metric: :cosine_distance

  @primary_key {:id, TP, type: "string", autogenerate: false}
  schema "card_stacks" do
    field :title, TP, type: "string", full_text_search: true, fuzzy: true
    field :markdown, TP, type: "string", full_text_search: true, embed: "openai/text-embedding-3-small"
    field :planbook_id, TP, type: "string"
    field :standard_ids, TP, type: "[]string"
    field :updated_at, TP, type: "datetime"
  end
end

import Ecto.Query
import TP.Query

MyApp.Search.insert!(%CardStack{id: "1", title: "Photosynthesis", markdown: "# Photosynthesis\n..."})

MyApp.Search.all(
  from c in CardStack,
    where: c.planbook_id == ^planbook_id and contains(c.standard_ids, ^standard_id),
    order_by: [desc: bm25(c.markdown, ^text) + 2.0 * bm25(c.title, ^text)],
    limit: 20,
    select: {c, dist()}
)
```

## Setup

```elixir
# mix.exs
{:ecto_turbopuffer, github: "commoncurriculum/ecto-turbopuffer"}

# lib/my_app/search.ex
defmodule MyApp.Search do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Turbopuffer
end

# config/runtime.exs
config :my_app, MyApp.Search,
  api_key: System.fetch_env!("TURBOPUFFER_API_KEY"),
  region: "gcp-us-central1"
```

Add `MyApp.Search` to your supervision tree like any other repo.

## The pieces

- **`TP`** is the Ecto type, the turbopuffer counterpart of [`Ch`](https://github.com/plausible/ch). `type:` takes
  turbopuffer's type strings (`"string"`, `"[]uuid"`, `"[1536]f16"`, `"{}f16"`, ...) and every other option is a
  turbopuffer schema option (`full_text_search:`, `filterable:`, `ann:`, `embed:`, ...). Both are checked at compile
  time, along with turbopuffer's namespace limits. `use TP` sets the namespace's `distance_metric`.
- **`Ecto.Adapters.Turbopuffer`** maps `insert`, `update`, `delete`, `all`, `aggregate`, `update_all`, `delete_all`
  and `union_all` onto turbopuffer's write and query APIs. Its moduledoc lists what maps to what, and the limits.
- **`TP.Query`** adds turbopuffer's search and filter operators to `Ecto.Query`: `bm25`, `ann`, `knn`,
  `sparse_knn`, `embed`, `fuzzy`, `regex`, `contains_all_tokens`, `dist`, and so on.

HTTP goes through the [`turbopuffer`](https://github.com/commoncurriculum/turbopuffer) driver, our fork of
[jallum/turbopuffer](https://github.com/jallum/turbopuffer) whose `combined` branch carries the fixes we've proposed
upstream. The driver works without Ecto; `Ecto.Adapters.Turbopuffer.client(MyApp.Search)` returns the repo's
`Turbopuffer.Client` for calls like namespace metadata, deletion, or anything else the adapter doesn't cover.
Typed results stay here, in `TP`, because turbopuffer's JSON doesn't say which strings are datetimes or uuids.

turbopuffer has no nested attributes, so documents are flat: every field is a `TP` field.

## Searching

```elixir
# Full-text search, highest score first.
from c in CardStack, order_by: [desc: bm25(c.markdown, ^text)], limit: 20

# Vector search with turbopuffer's native embedding, closest first.
from c in CardStack, order_by: ann(c.markdown, embed(^text)), limit: 20

# Hybrid: run both as one multi-query and fuse them with reciprocal rank fusion.
text = from c in CardStack, order_by: [desc: bm25(c.markdown, ^q)], limit: 50
vector = from c in CardStack, order_by: ann(c.markdown, embed(^q)), limit: 50
MyApp.Search.all(union_all(text, ^vector), rerank_by: {:rrf, limit: 20})
```

## Development

turbopuffer's documentation, as the Markdown it publishes, is in [`docs/turbopuffer/`](docs/turbopuffer). Refresh it
with `scripts/fetch-turbopuffer-docs.sh`.

The tests run against real turbopuffer, as its [testing guide](docs/turbopuffer/testing.md) recommends. Each test
writes to its own namespaces and deletes them afterwards.

```sh
TURBOPUFFER_API_KEY=... mix test
```

`TURBOPUFFER_REGION` defaults to `gcp-us-central1`.
