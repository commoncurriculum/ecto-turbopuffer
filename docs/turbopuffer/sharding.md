# Namespace Sharding

**Shard if:** a namespace would otherwise exceed the size limit of a
single index, or its size is bottlenecking indexing performance.

**Rule of thumb:** plan for one shard per terabyte of data. Leave room
for future growth. For example, a 3.2TB namespace needs at least 4 shards.
Use more shards if you expect the namespace to grow past 4TB.

```
                                    ╔═namespace═══════════════════════════╗
╔══════════╗                        ║ ┏━/wal (shared)━━━━━━━━━━━━━━━━━━━┓ ║░
║  Client  ║──writes & queries─────▶║ ┃■■■■■■■■■■■■■■■■■■■■■■◈◈◈◈       ┃ ║░
╚══════════╝░                       ║ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ ║░
 ░░░░░░░░░░░░                       ║      │ hash(id) % num_shards        ║░
                                    ║      ├───────────┬───────────┐      ║░
                                    ║      ▼           ▼           ▼      ║░
                                    ║ ┌─────────┐ ┌─────────┐ ┌─────────┐ ║░
                                    ║ │ shard 0 │ │ shard 1 │ │ shard N │ ║░
                                    ║ │  index  │ │  index  │ │  index  │ ║░
                                    ║ └─────────┘ └─────────┘ └─────────┘ ║░
                                    ╚═════════════════════════════════════╝░
                                     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

By default, a namespace is backed by a single index, which keeps reads and
writes simple and is the right choice for the vast majority of workloads.

**Namespace sharding** lets a single namespace scale beyond the size of one
index by transparently partitioning its documents across multiple internal
**shards**. Clients keep talking to one namespace; the engine fans writes and
queries out to the shards and merges results internally. There is no
client-side fan-out and no additional API.

- **One namespace, many indexes.** Documents are mapped to shards by `hash(id) %
  num_shards`, so each shard owns a roughly equal slice of the data.
- **Transparent writes.** Writes go to the namespace; each shard indexes only
  its assigned documents.
- **Transparent reads.** Queries fan out across shards and are merged into one
  response.
- **Single write-ahead log.** A write commits once to a shared log with
  all-or-nothing semantics, so a subsequent read sees it immediately.

## When to use sharding

Sharding is a good fit when:

* **A namespace would exceed the 1TB size limit
  of a single index.** Sharding raises the namespace's ceiling to
  256TB.
* **Index size is bottlenecking write performance.** When a single index is
  large enough to slow down indexing, spreading the data across shards lets
  each shard index its slice of the namespace independently.

For most namespaces, the default single-index path is the best choice. Reach for
sharding only when size is the constraint.

## How it works

1. You set a `sharding` configuration on the namespace's first write, choosing
   `num_shards`.
2. turbopuffer partitions documents across that many shards by
   `hash(id) % num_shards`. Each shard is its own index, but all shards share
   the same write-ahead log and namespace metadata.
3. Writes commit once to the shared log; each shard indexes only the documents
   assigned to it.
4. Queries scatter to every shard and are merged into a single response.

You read and write exactly as you would with any namespace. The engine handles
partitioning, fan-out, and merging.

Queries are [strongly consistent](/docs/guarantees) by default, and sharding
preserves this: for strongly consistent queries, each shard reads from the same
snapshot of the namespace, so the merged result reflects a single consistent
view. [Eventually consistent](/docs/query#param-consistency) queries are weaker
on a sharded namespace: each shard may serve results from a different snapshot,
based on its local indexing progress.

## Sizing

| Limit | Value | Notes |
|---|---|---|
| Max size per shard | 1TB | Pick `num_shards` so each shard stays under this limit. |
| Max documents per shard | 500M | Soft limit; performance depends on query complexity. |
| Max shards per namespace | 256 | |
| Effective max namespace size | 256TB | 256 shards × 1TB. |

As a sizing rule of thumb, set `num_shards ≈ ceil(expected logical size / 1 TB)`
and round up for headroom. Shard count can't be changed in place, so size for
growth. If you need a different count later, [copy into a new
namespace](#configuration) with a new `num_shards`.

That said, avoid over-sharding: every query waits on every shard, so a slow
shard sets the tail latency, and more shards make that more likely. Extra shards
also delay volume discounts on query pricing (see [Pricing](#pricing)).

There isn't a limit we can't improve by an order of magnitude when prioritized.
If you expect to brush up against one of these, [contact us](/contact).

## Pricing

Sharding does not change turbopuffer's [pricing](/pricing): you pay the same
per-unit rates for the data you store, write, and query, and there is no
per-shard fee. A sharded namespace with 8 shards costs the same to store and
write to as an unsharded namespace of the same size.

A query is billed by the size of the namespace it searches, with marginal
discounts as that size grows (see [pricing](/pricing)). On a sharded namespace,
a query fans out to every shard and each sub-query bills its shard's size, so
the total billed size is the same as for an unsharded namespace with the same
data. The one caveat is the discounts: they are computed from each shard's size
rather than the whole namespace's, so queries on a sharded namespace earn them
later.

## Pinning

Sharding composes with [namespace pinning](/docs/pinning). When a sharded
namespace is pinned, each shard is pinned individually, keeping its slice of
the data warm on its own reserved query nodes. Replicas apply per shard: a
namespace with 8 shards and 2 replicas reserves 16 query nodes.

Pinning is billed by GB-hours on the namespace's total size, regardless of the
number of shards, so sharding does not affect the cost of pinning.

## Configuration

Sharding is set via the [`sharding` write parameter](/docs/write#param-sharding)
on the namespace's inaugural write, or when creating a namespace with
[`copy_from_namespace`](/docs/write#param-copy_from_namespace). It cannot be
added to or changed on an existing namespace in place.

Re-sending the identical configuration on later writes is allowed; changing it
is rejected.

```json
POST /v2/namespaces/:namespace
{
  "upsert_rows": [
    { "id": 1, "vector": [0.1, 0.1] }
  ],
  "distance_metric": "cosine_distance",
  "sharding": { "num_shards": 8 }
}
```

To change shard count (or shard an unsharded namespace), copy into a new
namespace with a different `sharding` configuration:

```json
POST /v2/namespaces/:namespace-resharded
{
  "copy_from_namespace": "source-namespace",
  "sharding": { "num_shards": 16 }
}
```

Inspect the current configuration with `GET /v1/namespaces/:namespace/metadata`
(see [Metadata](/docs/metadata#responsefield-sharding)).

## Limitations

Current restrictions:

* **No in-place resharding**. `num_shards` is set on the namespace's first write
  and can't be changed afterward. Use [`copy_from_namespace`](/docs/write#param-copy_from_namespace)
  with a different `sharding` config to create a resharded copy.
  Online resharding is on the roadmap.
* **[Branching](/docs/branching) is not yet supported** on sharded namespaces.
* **Assignment is fixed** to `hash(id) % num_shards`; custom routing is not yet
  available.


---

This page: [/docs/sharding.md](https://turbopuffer.com/docs/sharding.md)

All documentation pages: [/llms.txt](https://turbopuffer.com/llms.txt)

All documentation in one file: [/llms-full.txt](https://turbopuffer.com/llms-full.txt)
