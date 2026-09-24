# AGENTS.md

[`README.md`](./README.md) covers what this library is and how to run it.

## turbopuffer's docs

turbopuffer's documentation is checked in, as the Markdown it publishes, at [`docs/turbopuffer/`](docs/turbopuffer).
Read it there instead of searching the web: [`write.md`](docs/turbopuffer/write.md) (writes and the schema),
[`query.md`](docs/turbopuffer/query.md) (queries and filters), [`limits.md`](docs/turbopuffer/limits.md), and
[`llms.txt`](docs/turbopuffer/llms.txt) for the index. Refresh it with `scripts/fetch-turbopuffer-docs.sh`.

Where the docs and the live API disagree, the live API wins, and a test should pin the behavior. Known cases:

- base64 vectors in query responses use the schema's element type (writes always take f32)
- aggregation queries take `top_k`, not `limit`
- patches can't change attributes turbopuffer embeds natively, not only vectors
- deleting an id that doesn't exist still counts as deleted, unless the delete has a `delete_condition`

## Commands

- Versions: `.tool-versions` (Elixir 1.17.3, OTP 25, matching the app that uses this library)
- Tests: `TURBOPUFFER_API_KEY=... mix test`
- Format: `mix format`, checked with `mix format --check-formatted`
- Compile: `mix compile --warnings-as-errors`

## Tests

Tests hit real turbopuffer. Never mock, stub, or fake it. `TP.Test.Case` gives each test its own namespace prefix
and deletes those namespaces afterwards, so tests can run concurrently against the same account.

## Comments

A comment earns its place only by saying something the code can't: the constraint, the trap, the reason something
looks wrong but is right. No method summaries, dated decisions, or references to chats.
