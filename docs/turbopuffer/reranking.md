# Reranking

Native reranking uses an ML model to reorder the results returned by vector
search, full-text search, hybrid search, or another ranking function, so that
the documents most relevant to the query come first. You don't need to integrate with a
reranking provider or manage a separate API key. turbopuffer sends the
candidates to the model and returns the reordered results.

## An introduction to rerankers

Most search systems work in two stages. The first stage searches the whole
namespace and narrows millions of documents down to a small set of candidates
that are likely to contain the answer. If the answer is a needle, the first
stage picks out the few haystacks it is most likely to be in. The second stage
searches through those haystacks: a reranker reads each candidate closely and
puts the most relevant ones first. We recommend adding this second stage to
nearly every search application, unless it can't afford the latency of a model
inference step on each query.

Take a simple example where the query is "How do I reset my password?".
First-stage retrieval returns five documents, but ranks password policy and
billing ahead of reset password and forgot password. Running the query and
those five documents through a reranking model with `rerank_by` puts the most
relevant documents first.

```
                ╔═ rank_by ══════════════╗   ╔═ rerank_by ════════════╗
                ║  top 5                 ║░  ║  by relevance          ║░
                ║ ┌────────────────────┐ ║░  ║ ┌────────────────────┐ ║░
┌────────────┐  ║ │ 1 password policy  │ ║░  ║ │ 1 reset password   │ ║░
│ "How do I  │  ║ │ 2 billing          │ ║░  ║ │ 2 forgot password  │ ║░
│ reset my   │─▶║ │ 3 account settings │ ║░─▶║ │ 3 password policy  │ ║░
│ password?" │  ║ │ 4 reset password   │ ║░  ║ │ 4 account settings │ ║░
└────────────┘  ║ │ 5 forgot password  │ ║░  ║ │ 5 billing          │ ║░
                ║ └────────────────────┘ ║░  ║ └────────────────────┘ ║░
                ║                        ║░  ║                        ║░
                ╚════════════════════════╝░  ╚════════════════════════╝░
                 ░░░░░░░░░░░░░░░░░░░░░░░░░░   ░░░░░░░░░░░░░░░░░░░░░░░░░░
```

Reranking models judge relevance more accurately because they read the query
and each document together as a pair. Embedding models, by contrast, encode the
query and the documents separately, and BM25 scores documents by matching
terms. That accuracy costs compute, and each stage spends more compute per
document than the one before it. First-stage retrieval is cheap enough per
document to cover the whole namespace. A reranker runs a model on every document
it scores, which is affordable only because it sees just the candidates.

Here is the password example as an API request, retrieving 100 candidates
instead of 5. First-stage retrieval is set by `rank_by`, and reranking by the
`rerank_by` object, which specifies:

- `model`: the reranking model to use
- `attribute`: the stored text attribute to score
- `query`: the text to score each document against

Reranking currently scores one attribute per query, and that attribute must
also be listed in `include_attributes`.

<!-- multilang -->

```python
from turbopuffer import Turbopuffer

ns = Turbopuffer(region="gcp-us-central1").namespace("docs")
query = "How do I reset my password?"

response = ns.query(
    rank_by=("text", "BM25", query),
    limit=100,
    include_attributes=["text"],
    rerank_by={
        "model": "voyage/rerank-3",
        "attribute": "text",
        "query": query,
    },
)
```

```rust
use turbopuffer::Client;
use turbopuffer::serde_json;
use turbopuffer::types::{RankBy, RerankModelParams};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::builder().region("gcp-us-central1").build()?;
    let ns = client.namespace("docs");
    let query = "How do I reset my password?";

    let response = ns
        .query()
        .rank_by(RankBy::bm25("text", query))
        .limit(100)
        .include_attributes(["text"])
        .rerank_by(RerankModelParams::new("voyage/rerank-3", "text", query))
        .send()
        .await?;
    println!("{}", serde_json::to_string_pretty(&response.rows)?);

    Ok(())
}
```

```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({ region: "gcp-us-central1" });
const ns = tpuf.namespace("docs");
const query = "How do I reset my password?";

const response = await ns.query({
  rank_by: ["text", "BM25", query],
  limit: 100,
  include_attributes: ["text"],
  rerank_by: {
    model: "voyage/rerank-3",
    attribute: "text",
    query,
  },
});
```

<!-- /multilang -->

The response includes the document ID and requested attributes:

```jsonc
{
  "rows": [
    {
      "id": "password-reset",
      "text": "To reset your password, click 'Forgot password' on the sign-in page.",
      "$dist": 0.92
    },
    ...
  ]
}
```

`$dist` is the reranking model's relevance score, and it replaces the
first-stage retrieval score. Results are sorted by this score, highest first.
To return the first-stage score as well, see
[Keep the first-stage retrieval score](#keep-the-first-stage-retrieval-score).
Scores aren't comparable across models, but with the same model and query they
are comparable across namespaces and requests, so you can merge results and
sort them by `$dist`.

Reranking improves the order only when `rank_by` has already retrieved relevant
documents. The model only reorders that set, which means that a relevant document
that is missing from it stays missing. A larger `limit` gives the model more
documents to consider, but also adds more reranking work and increases latency.

## Pricing

Reranking is billed per million input tokens processed by a model. The model
scores each candidate as a query and document pair, so the query is counted
once per candidate. How your query and documents translate into tokens is model
dependent. A rough rule of thumb is that 4 bytes of English text is about 1
token.

See the [list of available models](#models) for pricing. Standard
[query charges](/pricing) still apply.

**Example:** an application reranks every query with `voyage/rerank-3`.

- Each query reranks 100 candidates of about 200 tokens each (roughly 800
  bytes of English text). The query itself is about 10 tokens.
- The query is counted once per candidate, so each query processes
  100 × (200 + 10) = 21,000 tokens.
- At 1 query per second, the application runs about 2.6 million queries a
  month (86,400 seconds a day × 30 days), or about 54 billion tokens.
- At $0.05 per million tokens, reranking costs about $2,700 a month, on top
  of standard query charges.
- Reranking 50 candidates instead of 100 halves that.

## Models

| Model | Price ($/1M tokens) | Context length | Inference | Namespace regions |
| --- | --- | --- | --- | --- |
| `cohere/rerank-v3.5` | $0.10 | 4,096 tokens | US | `aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`, `gcp-us-central1`, `gcp-us-east1`, `gcp-us-west1`, `gcp-us-east4` |
| `typesafe/jev-1.13.0` | TBD | 32,000 tokens | US | `aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`, `gcp-us-central1`, `gcp-us-east1`, `gcp-us-west1`, `gcp-us-east4` |
| `voyage/rerank-3` | $0.05 | 32,000 tokens | Global | `aws-eu-central-1`, `aws-eu-west-1`, `aws-eu-west-2`, `aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`, `gcp-us-central1`, `gcp-us-east1`, `gcp-us-west1`, `gcp-us-east4`, `gcp-europe-west3`, `gcp-europe-west1` |
| `voyage/rerank-3-lite` | $0.02 | 32,000 tokens | Global | `aws-eu-central-1`, `aws-eu-west-1`, `aws-eu-west-2`, `aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`, `gcp-us-central1`, `gcp-us-east1`, `gcp-us-west1`, `gcp-us-east4`, `gcp-europe-west3`, `gcp-europe-west1` |
| `zeroentropy/zerank-2` | $0.025 | 32,768 tokens | EU | `aws-eu-central-1`, `aws-eu-west-1`, `aws-eu-west-2`, `gcp-europe-west3`, `gcp-europe-west1` |
| `zeroentropy/zerank-2` | $0.025 | 32,768 tokens | US | `aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`, `gcp-us-central1`, `gcp-us-east1`, `gcp-us-west1`, `gcp-us-east4` |

- Context length is the maximum number of input tokens a model will consider
  when scoring a query-document pair, including any model-specific prompting.

### Choosing the right model

A reranking model can perform well on public benchmarks and still be a poor
fit for your search. Your terminology, document lengths, and users'
expectations all affect relevance. A small evaluation on your own data helps
you see whether reranking makes a useful difference.

Start with a handful of queries that reflect how people use your application.
Identify which documents would help answer each query, including queries your
search already handles well so you can catch regressions. You don't need to
label your entire dataset: inspecting a few result sets is enough to start
seeing where the ordering could improve.

Run each query without `rerank_by` as a baseline, then try different models
while keeping first-stage retrieval unchanged. Keep the namespace contents,
`rank_by`, `limit`, `include_attributes`, `rerank_by.attribute`, and
`rerank_by.query` the same; change only `rerank_by.model`. The model is chosen
per query, so switching models doesn't require a reindex. Compare the documents
in the first five or ten results, rather than their `$dist` values: scores
aren't comparable across models.

The table below shows common outcomes and what they tell you:

| What happened? | Before reranking | After reranking | What it tells you |
| --- | --- | --- | --- |
| A relevant document was buried in the results | 40th of 100 candidates | 2nd | Reranking made it more likely that the user would find the answer. |
| Search already put the relevant document first | 1st | 1st | This query gained no improvement in the document's position, but still incurred reranking latency and cost. |
| A relevant document moved down | 2nd | 15th | Reranking made this query worse. Keep these regressions in your comparison. |
| The relevant document wasn't retrieved | Missing from the 100 candidates | Still missing | Improve first-stage retrieval, for example by increasing `limit` or trying hybrid search. Changing the reranker cannot recover a missing candidate. |
| No document in the namespace answers the query | No relevant result | Still no relevant result | As in the previous case, a better reranker can't fix this. |

Once a model consistently improves the results, compare its added latency and
cost to decide whether the improvement is worthwhile for your application.

## Examples

### Keep the first-stage retrieval score

Because `$dist` contains the reranking score, the score from `rank_by` isn't
returned by default. To keep it, add the same expression as a
[computed attribute](/docs/query#param-compute_attributes). Computed attributes
don't change which documents are retrieved or how they are ranked.

<!-- multilang -->

```python
from turbopuffer import Turbopuffer

ns = Turbopuffer(region="gcp-us-central1").namespace("docs")
query = "How do I reset my password?"

response = ns.query(
    rank_by=("text", "BM25", query),
    limit=100,
    include_attributes=["text"],
    compute_attributes={"bm25_score": ("text", "BM25", query)}, # same as in `rank_by`
    rerank_by={
        "model": "voyage/rerank-3",
        "attribute": "text",
        "query": query,
    },
)
```

```rust
use turbopuffer::Client;
use turbopuffer::serde_json;
use turbopuffer::types::{RankBy, RerankModelParams};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::builder().region("gcp-us-central1").build()?;
    let ns = client.namespace("docs");
    let query = "How do I reset my password?";

    let response = ns
        .query()
        .rank_by(RankBy::bm25("text", query))
        .limit(100)
        .include_attributes(["text"])
        .compute_attributes([("bm25_score", RankBy::bm25("text", query))]) // same as in `rank_by`
        .rerank_by(RerankModelParams::new("voyage/rerank-3", "text", query))
        .send()
        .await?;
    println!("{}", serde_json::to_string_pretty(&response.rows)?);

    Ok(())
}
```

```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({ region: "gcp-us-central1" });
const ns = tpuf.namespace("docs");
const query = "How do I reset my password?";

const response = await ns.query({
  rank_by: ["text", "BM25", query],
  limit: 100,
  include_attributes: ["text"],
  compute_attributes: { bm25_score: ["text", "BM25", query] }, // same as in `rank_by`
  rerank_by: {
    model: "voyage/rerank-3",
    attribute: "text",
    query,
  },
});
```

<!-- /multilang -->

Each row then includes both scores:

```jsonc
{
  "id": "password-reset",
  "text": "To reset your password, click 'Forgot password' on the sign-in page.",
  "bm25_score": 7.4,
  "$dist": 0.92
}
```

For vector search, use a `VectorDist` expression to return the vector distance
instead. In a multi-query, a computed attribute with the same name must have
the same definition in every subquery.

### Search titles and rerank using document bodies

The query you rerank with doesn't have to be the query you retrieve with.
Because a reranker reads the query and each document together, it can use
detailed context to judge which document applies. If your application has that
context on hand, pass it in `rerank_by.query` and keep a short query for
first-stage retrieval.

In this example, a support agent searches a knowledge base for "refund" while a
customer ticket is open. First-stage retrieval matches "refund" against article
titles, and the reranker scores each article's body against the ticket and the
agent's query. The example assumes `title` has [full-text search](/docs/fts)
enabled and `body` is a stored string attribute.

<!-- multilang -->

```python
from turbopuffer import Turbopuffer

ns = Turbopuffer(region="gcp-us-central1").namespace("support-articles")
query = "refund"
ticket = "I was charged twice for my March invoice. The duplicate shows as pending on my card. Can you reverse it?"

response = ns.query(
    rank_by=("title", "BM25", query),
    limit=100,
    include_attributes=["title", "body"],
    rerank_by={
        "model": "voyage/rerank-3",
        "attribute": "body",
        "query": f"{ticket}\n\nQuery: {query}",
    },
)
```

```rust
use turbopuffer::Client;
use turbopuffer::serde_json;
use turbopuffer::types::{RankBy, RerankModelParams};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::builder().region("gcp-us-central1").build()?;
    let ns = client.namespace("support-articles");
    let query = "refund";
    let ticket = "I was charged twice for my March invoice. \
        The duplicate shows as pending on my card. Can you reverse it?";

    let response = ns
        .query()
        .rank_by(RankBy::bm25("title", query))
        .limit(100)
        .include_attributes(["title", "body"])
        .rerank_by(RerankModelParams::new(
            "voyage/rerank-3",
            "body",
            format!("{ticket}\n\nQuery: {query}"),
        ))
        .send()
        .await?;
    println!("{}", serde_json::to_string_pretty(&response.rows)?);

    Ok(())
}
```

```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({ region: "gcp-us-central1" });
const ns = tpuf.namespace("support-articles");
const query = "refund";
const ticket =
  "I was charged twice for my March invoice. The duplicate shows as pending on my card. Can you reverse it?";

const response = await ns.query({
  rank_by: ["title", "BM25", query],
  limit: 100,
  include_attributes: ["title", "body"],
  rerank_by: {
    model: "voyage/rerank-3",
    attribute: "body",
    query: `${ticket}\n\nQuery: ${query}`,
  },
});
```

<!-- /multilang -->

Several articles have "refund" in the title, including "Refund policy" and
"Reversing a duplicate charge". The titles alone don't say which one applies,
but the ticket does, and it gives the reranker what it needs to rank the
duplicate-charge article above the general policy.

The ticket is sent to the model once per candidate, so a long rerank query
multiplies tokens by `limit`. It also counts toward the model's
[context length](#models) for every pair, which leaves less room for the
document body. Reranking also cannot recover an article that the title search
missed, such as one titled "Duplicate charges" that never says "refund". To use
the ticket in first-stage retrieval as well, add an `ANN` subquery that embeds
the ticket, using the multi-query pattern in the hybrid search example.

### Hybrid search with native embeddings

Retrieve candidates with both BM25 and vector search, then rerank their combined
results. This example assumes `text` has both
[native embeddings](/docs/embedding) and [full-text search](/docs/fts) configured.

<!-- multilang -->

```python
from turbopuffer import Turbopuffer

ns = Turbopuffer(region="gcp-us-central1").namespace("docs")
query = "How do I reset my password?"

response = ns.multi_query(
    queries=[
        {
            "rank_by": ("text", "BM25", query),
            "limit": 100,
            "include_attributes": ["text"],
        },
        {
            "rank_by": ("text", "ANN", ("Embed", query)),
            "limit": 100,
            "include_attributes": ["text"],
        },
    ],
    rerank_by={
        "model": "voyage/rerank-3",
        "attribute": "text",
        "query": query,
    },
    limit=10,
)

results = response.results[0].rows
```

```rust
use turbopuffer::Client;
use turbopuffer::serde_json;
use turbopuffer::types::{Expr, Query, RankBy, RerankModelParams};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::builder().region("gcp-us-central1").build()?;
    let ns = client.namespace("docs");
    let query = "How do I reset my password?";

    let response = ns
        .multi_query([
            Query::new()
                .rank_by(RankBy::bm25("text", query))
                .limit(100)
                .include_attributes(["text"]),
            Query::new()
                .rank_by(RankBy::ann("text", Expr::embed(query)))
                .limit(100)
                .include_attributes(["text"]),
        ])
        .rerank_by(RerankModelParams::new("voyage/rerank-3", "text", query))
        .limit(10)
        .send()
        .await?;

    let results = &response.results[0].rows;
    println!("{}", serde_json::to_string_pretty(results)?);

    Ok(())
}
```

```typescript
import { Turbopuffer } from "@turbopuffer/turbopuffer";

const tpuf = new Turbopuffer({ region: "gcp-us-central1" });
const ns = tpuf.namespace("docs");
const query = "How do I reset my password?";

const response = await ns.multiQuery({
  queries: [
    {
      rank_by: ["text", "BM25", query],
      limit: 100,
      include_attributes: ["text"],
    },
    {
      rank_by: ["text", "ANN", ["Embed", query]],
      limit: 100,
      include_attributes: ["text"],
    },
  ],
  rerank_by: {
    model: "voyage/rerank-3",
    attribute: "text",
    query,
  },
  limit: 10,
});

const results = response.results[0].rows;
```

<!-- /multilang -->

Each subquery retrieves up to 100 candidates. turbopuffer merges the results,
deduplicates documents by ID, and scores each document once. The outer `limit`
returns the best 10 after reranking. Set `rerank_by` on the outer request and
include the text attribute in every subquery.

You don't need to apply RRF first: model reranking scores the combined candidates
directly. [RRF](/docs/query#reciprocal-rank-fusion) is another way to combine
subquery results, using their ranks rather than a model.

## Limitations

- Reranking requires a stored `string` attribute. Include it in
  [`include_attributes`](/docs/query#param-include_attributes) in every query.
  You can return other attributes alongside it.
- You can return [computed attributes](/docs/query#param-compute_attributes)
  alongside reranked results, but you can't rerank on a computed attribute.
  Aggregation queries are not supported with model reranking.
- Documents with a missing or null reranking attribute are not sent to the
  model and receive a score of zero.
- Reranking adds a model inference step after first-stage retrieval. Latency
  depends on the model, the number of candidates, and the length of their text.
- Model availability varies by region. Use the region selector in the
  [model table](#models) to check your region.

If your use case is blocked by one of these limitations or you'd like to use a model that isn't listed here, [contact us](/contact).

### Rate Limits

The default limit is 2,500 candidate documents per second per organization and
model, with a burst capacity of 10,000 documents. These limits are separate
from embedding limits. Reranking 100 candidates and returning 10 counts as
100 documents; duplicates across subqueries count once.

Rate-limited requests fail in full with HTTP `429 Too Many Requests`.
[Contact us](/contact) for higher limits.

## Security

We work with external partners to provide access to reranking models. When you
use reranking, the query in `rerank_by` and the selected text attribute from
each candidate document are sent from our cloud account to the model's
provider. Other returned attributes are not sent. The provider depends on the
[model you select](#models). See our
[subprocessors](/docs/security/subprocessors) page for our inference providers.


---

This page: [/docs/reranking.md](https://turbopuffer.com/docs/reranking.md)

All documentation pages: [/llms.txt](https://turbopuffer.com/llms.txt)

All documentation in one file: [/llms-full.txt](https://turbopuffer.com/llms-full.txt)
