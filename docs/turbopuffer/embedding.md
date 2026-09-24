# Embedding

Native embeddings convert your documents and queries into vectors as you read
from and write to turbopuffer. You don't need to write any code to integrate
with an embedding provider. Instead, turbopuffer handles embedding your data on
writes and queries.

Native embeddings are stored as a vector alongside the data that was embedded.
You can read and export the source data and the native embedding vectors like
you can any other field. You always own the data you store in turbopuffer.

To enable native embedding, use the `embed` property on an attribute's schema to
specify an embedding model. Writes and queries to that attribute are turned into
vectors on the fly.

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

// create a new namespace with native embeddings
const ns = tpuf.namespace(`embedding-intro-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      text: "A cat sleeping on a windowsill",
      category: "animal",
    },
    {
      id: 2,
      text: "A playful kitten chasing a toy",
      category: "animal",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: {
      type: "string",
      // use native embeddings by setting the `embed` property on a text
      // attribute to your favorite model
      embed: "nvidia/nemotron-3-embed-8b",
    },
  },
});
```
<!-- /multilang -->

## Pricing

Embedding is billed based on the number of tokens embedded by a model. How your
document translates into tokens is model dependent. A rough rule of thumb is
that 4 bytes of English text is about 1 token. The number of tokens embedded is
included in both the [query](/docs/query#responsefield-performance) and
[write](/docs/write#responsefield-performance) responses.

See the [list of available models](/docs/embedding#models) for pricing.

Use the calculator below to estimate monthly embedding cost from document size,
query size, model price, and write/query volume.

## Limitations

Native embeddings have a few limitations. Like our [other limits](/docs/limits),
there is nothing here that we can't improve if prioritized. If your native
embeddings use case is blocked by one of these limits, [contact us](/contact).

- Native embeddings always store the source document in turbopuffer, along with
  the embedding vector.

- You're constrained by our rate limits. We work tirelessly with our partners to
  make sure turbopuffer can embed as fast as it can index, but there may be
  situations where we have to rate-limit and return 429s. We keep a close eye on
  our capacity and scale up within and across providers to make sure you can
  keep puffin'. We treat any period of prolonged rate-limiting as a bug.

- Setting `embed` on an attribute does not yet automatically re-embed it with
  the specified model. Only subsequent writes are affected, so if you decide to
  change your embedding model you have to re-ingest the data in your namespaces.

- Multi-modal support is a work-in-progress. There is no dedicated
  [type](/docs/write#param-type) for image or video data, so to use multi-modal
  embeddings your source data must be stored as a base64 encoded `string`
  attribute.

- We don't yet support contextual models that chunk their inputs and produce a
  variable number of vectors. We want to get the API right before we make them
  available.

### Rate Limits

We manage rate limits at the organization level to provide [tenant
isolation](/docs/architecture). We currently limit new organizations to 1024
requests per minute and 2M tokens per minute for each model we support, but aim
to increase this over time. [Contact us](/contact) at any time and we'll raise
your rate limit to match your workload.

Rate limits are opaque - there is no way to know how close you are to your
limits. When limited, the API will return an HTTP `429 Too Many Requests`
response with an appropriate message to let you know you've been rate limited.
Each request is accepted or rate limited in full. For example, a large batch write may exceed your remaining capacity even when a smaller query would be accepted.

## Models

The following models are currently available as managed embedding models. If you
see a model you'd like to use that isn't listed here, please [get in touch](/contact).
The [embedding changelog](/docs/embedding/changelog) tracks the models we've
added, deprecated, and repriced over time.

A model listed here without a price is still available, but pricing is TBD.
We'll always try to work with our partners to price match your existing
embedding provider.

### Recommendations

Picking an embedding model can deeply impact the quality, cost, and latency of
your retrieval pipeline. Unfortunately, it's both a difficult decision and one
that's hard to change (though we're working on making it easy). The quality of
an embedding model is highly dependent on exactly what you're searching over.
The best way to choose an embedding model is to [run an
eval](https://georgianailab.substack.com/p/evaluating-retrieval-without-ground)
that measures how an embedding model affects your application. If you can't do
that, the [RTEB](https://huggingface.co/spaces/embedding-benchmark/RTEB)
scores in the table below are an ok guide.

When picking a model, we recommend thinking about the quality, cost, and latency
tradeoffs in your application. It may be tempting to always pick the "best"
model, but if you need interactive search your users may be more sensitive to
latency than they are to slightly worse recall. Conversely, if you're powering a
search agent it may be better to spend more up-front on an embedding model to
reduce the number of tokens the agent needs to answer questions. 

### Supported models

The following models are supported for native embeddings. Click on a model in
the table below for detailed information.

- Context length is the maximum number of input tokens a model will consider
  in an individual embedding input.

- Inputs longer than a model's context length are **truncated by default**, so a
  long document is embedded from its beginning rather than rejected.

- Models that distinguish queries from documents are prompted for you: we send
  the right input type, or prepend the model's own prompt prefix, depending on
  whether the text comes from a write or a query. You don't have to add
  anything to your text.

- The dimension marked `(default)` is the model's default output dimension.

- The listed [RTEB](https://huggingface.co/spaces/embedding-benchmark/RTEB)
  score is the overall score. 

- Use the region selector above the table to see which models are available in
  each [region](/docs/regions).

- Every model runs with zero data retention: our
  [inference providers](/docs/security/subprocessors) do not store the content
  you send, and do not train on it.

If you're interested in using a model not available in the list below [contact us](/contact).

### Deprecated models

The following models are available in native embeddings but are marked
deprecated. We'll support these models as long as we can to make migration easy,
but we strongly recommend against using them for new namespaces.

The deprecation date listed on a model is the earliest date at which we'll
remove support for a model.

## Examples

### Creating a new namespace

Create a new namespace with native embeddings on a `text` attribute.

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

// create a new namespace with native embeddings
const ns = tpuf.namespace(`embedding-new-namespace-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      text: "A cat sleeping on a windowsill",
      category: "animal",
    },
    {
      id: 2,
      text: "A playful kitten chasing a toy",
      category: "animal",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: {
      type: "string",
      // use native embeddings to set an embedding model and the size
      // of the embedding vector
      embed: {
        model: "nvidia/nemotron-3-embed-8b",
        dims: 1024,
      }
    },
  },
});

// future writes don't need to specify the schema or the `embed_text` attribute.
// the text attribute is turned into a vector on every write.
await ns.write({
  upsert_rows: [
    {
      id: 3,
      text: "An airplane flying through clouds",
      category: "vehicle",
    },
    {
      id: 4,
      text: "A shiny red sports car",
      category: "vehicle",
    },
  ]
})

// use the Embed function with ANN or kNN to turn text input into a vector
await ns.query({
  include_attributes: ["id", "text", "embed_text"],
  rank_by: ["text", "ANN", ["Embed", "something high energy"]],
  limit: 10,
});
```
<!-- /multilang -->

### Query-only native embeddings

If you've already invested in embedding a large batch of documents, you can
ingest them into turbopuffer and use native embeddings to query them.

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

function embed(_text: string, n: number = 1024): number[] {
  return Array.from({ length: n }, () => Math.random());
}

// creating a new namespace that uses your own embedding model to embed
// documents, and write a few documents into the namespace.
const ns = tpuf.namespace(`embedding-query-only-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      vector: embed("walrus narwhal"),
      public: true,
      text: "walrus narwhal",
    },
    {
      id: 2,
      vector: embed("pufferfish clownfish swordfish"),
      public: false,
      text: "pufferfish clownfish swordfish",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: { type: "string", full_text_search: true, regex: true },
  },
});

// use the Embed function with an explicit model to let native embeddings handle
// the query embeddings. this should match the model you're using to embed
// documents or you might get some strange results.
await ns.query({
  include_attributes: ["id", "text", "vector"],
  rank_by: ["vector", "ANN", ["Embed", "something high energy", {model: "nvidia/nemotron-3-embed-8b"}]],
  limit: 10,
});
```
<!-- /multilang -->

### Supplying your own vectors

With `embed` set, you can still provide a vector yourself. Each row that
includes a vector is stored as-is, and rows with no vector have one computed
by sending the attribute to an embedding provider.

That makes it possible to backfill vectors computed elsewhere while new
documents are embedded for you, and to roll a write path over to native
embeddings gradually instead of all at once.

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

function embed(_text: string, n: number = 1024): number[] {
  return Array.from({ length: n }, () => Math.random());
}

// create a namespace with native embeddings on `text`
const ns = tpuf.namespace(`embedding-supplied-vectors-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      text: "walrus narwhal",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: {
      type: "string",
      embed: {
        model: "nvidia/nemotron-3-embed-8b",
        attribute: "vector",
        dims: 1024,
      },
    },
  },
});

// backfill documents you already embedded elsewhere. these are stored as sent,
// and are never sent to the embedding provider.
await ns.write({
  upsert_rows: [
    {
      id: 2,
      vector: embed("pufferfish clownfish swordfish"),
      text: "pufferfish clownfish swordfish",
    },
    {
      id: 3,
      vector: embed("zebra horse antelope"),
      text: "zebra horse antelope",
    },
  ],
});

// you can mix and match pre-computed and native embeddings in the same write.
await ns.write({
  upsert_rows: [
    {
      id: 4,
      vector: embed("manatee dugong"),
      text: "manatee dugong",
    },
    {
      id: 5,
      text: "octopus cuttlefish",
    },
  ],
});

// queries are unaffected: every row has a vector either way
await ns.query({
  include_attributes: ["id", "text", "vector"],
  rank_by: ["text", "ANN", ["Embed", "a pointy fish"]],
  limit: 10,
});
```
<!-- /multilang -->

A vector you provide is stored exactly as sent. It has to match the vector
attribute's dimensionality and data type, but turbopuffer **does not** check that
it came from the configured model, or that it corresponds to the source text.

Mixing vectors from different models in one attribute will degrade your search
results.

Rows that supply a vector don't need the source attribute at all, which lets you
ingest data you no longer have the original text for. Those rows can't be
re-embedded later, though, so prefer writing the source text when you have it.

### Migrating to native embeddings 

To migrate an existing namespace to native embeddings, first switch your
application's reads to use native embeddings [on
query](/docs/embedding#query-only-native-embeddings) and then switch writes by
[updating the `embed` attribute](/docs/write#updating-attributes) on the
attribute to embed. Future ANN queries can use the `Embed` function to rank by
the source field directly.

You can still send your own vectors on writes, or mix and match. So you don't
have to switch every writer over at once. See [supplying your own
vectors](/docs/embedding#supplying-your-own-vectors).

Embedding an existing attribute into an existing vector does check that the
embedding model supports both the shape and datatype of the existing vector, but
**does not** check that the vectors semantically make sense and **does not**
re-embed the namespace. Before enabling native embedding on a namespace,
validate that the model already in use is compatible with the native embedding
model. 

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

function random_vector(_text: string, n: number = 1024): number[] {
  return Array.from({ length: n }, () => Math.random());
}

// create a new namespace without native embeddings
const ns = tpuf.namespace(`embedding-enable-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      vector: random_vector("walrus narwhal"),
      text: "walrus narwhal",
    },
    {
      id: 2,
      vector: random_vector("pufferfish clownfish swordfish"),
      text: "pufferfish clownfish swordfish",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: { type: "string", full_text_search: true, regex: true },
  },
});

// switch your queries to use query-time embedding
await ns.query({
  include_attributes: ["id", "text", "vector"],
  rank_by: ["vector", "ANN", ["Embed", "a pointy fish", {model: "nvidia/nemotron-3-embed-8b"}]],
  limit: 10,
});

// update your schema in-place to enable native embeddings
await ns.write({
  schema: {
    text: {
      type: "string",
      embed: {
        model: "nvidia/nemotron-3-embed-8b",
        attribute: "vector",
      },
    },
  },
});

// queries no longer need to specify a model
await ns.query({
  include_attributes: ["id", "text", "vector"],
  rank_by: ["text", "ANN", ["Embed", "lots and lots of blubber"]],
  limit: 10,
});

// and writes no longer need to include a vector
await ns.write({
  upsert_rows: [
    {
      id: 3,
      text: "zebra horse antelope",
    },
  ]
});
```
<!-- /multilang -->

### Disabling native embeddings 

To disable embedding, set `embed` to `null` on an attribute. After the write
succeeds, any future writes will require passing an explicit vector and any
future ANN queries will require passing a vector to `rank_by`. Any embedded
columns, including automatically generated embedding columns, are untouched
and can be queried as normal.

<!-- multilang -->
```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({
  region: "gcp-us-central1", // pick a region: https://turbopuffer.com/docs/regions
});

function random_vector(_text: string, n: number = 1024): number[] {
  return Array.from({ length: n }, () => Math.random());
}

// create a new namespace with native embeddings
const ns = tpuf.namespace(`embedding-disable-ts`);
await ns.write({
  upsert_rows: [
    {
      id: 1,
      text: "A cat sleeping on a windowsill",
      category: "animal",
    },
    {
      id: 2,
      text: "A playful kitten chasing a toy",
      category: "animal",
    },
  ],
  distance_metric: "cosine_distance",
  schema: {
    text: {
      type: "string",
      embed: {
        model: "nvidia/nemotron-3-embed-8b",
        dims: 1024,
      },
    },
  },
});

// disable native embeddings
await ns.write({
  schema: {
    text: {
      type: "string",
      embed: null,
    },
  },
});

// any future write to this namespace requires writing the embed_text vector
await ns.write({
  upsert_rows: [
    {
      id: 1,
      embed_text: random_vector("zebra horse antelope"),
      text: "zebra horse antelope",
    },
  ],
});
```
<!-- /multilang -->

## Security

We work with external partners to provide access to a wide range of embedding
models. When you use automatic embedding, your data is sent from our cloud
account to one of our embedding partners. The exact provider depends on the
[model you select](#supported-models). A full list of embedding providers is
available on our [subprocessors](/docs/security/subprocessors) page.

Our embedding partners are contractually bound to the same or equivalent data
protections outlined in our [DPA](/dpa), and do not train models on your data.
Zero Data Retention (ZDR) is maintained for all models: our partners do not
retain your embedding inputs beyond the lifetime of each request.


---

This page: [/docs/embedding.md](https://turbopuffer.com/docs/embedding.md)

All documentation pages: [/llms.txt](https://turbopuffer.com/llms.txt)

All documentation in one file: [/llms-full.txt](https://turbopuffer.com/llms-full.txt)
