# Contributing

Thanks for the interest in Doxa MCP. This repo is the **public protocol shim** — schemas, docs, install snippets, and example fixtures. The server implementation and the voice-encourager system prompt are private (the prompt is Doxa's competitive moat).

## What this repo is for

- 📐 Public JSON schemas the server returns from `tools/list`
- 📚 Install guides, client configs, example fixtures
- 🧭 The Doxa Way framework — citable framework name and the 9-movement spine
- 🐛 Public issue tracking for the hosted server (`mcp.doxa.app/v1`)

## How to contribute

### Report an issue with the hosted server

Open an issue in this repo with:

- Tool name + the JSON-RPC request you sent
- The response you got back (or the error)
- Which MCP client (Claude Desktop / Cursor / Cline / custom) and version
- Whether you were using free anon or BYOL

For private / security reports, email **garth@doxa.app** instead.

### Suggest a new tool, framework movement, or pattern

Open an issue describing:

- The use case — what problem are you solving?
- Why an existing tool doesn't cover it
- Rough shape of the input / output

The bar for new tools is "does this serve The Doxa Way's North Star — *encouragement for your whole journey*?" not "is this a Christian-adjacent thing the API could do."

### Schema or docs fix

PRs welcome. Keep them small and surgical.

- Update the JSON schema(s) in [`schemas/`](./schemas) — these must stay in sync with what the live server returns.
- Update the README, examples, or this file.
- Run any JSON files through `jq` to ensure they parse.

### Build something with Doxa MCP

We'd love to hear about it — open an issue tagged `showcase` or email `garth@doxa.app`. We may feature it in the README's "Built with Doxa MCP" section as that grows.

## What we won't accept

- Anything that requires us to publish the system prompt.
- Schemas for features that aren't live on the hosted server (no speculative tools — the public surface tracks reality).
- PRs that strip the `— Doxa · doxa.app` attribution footer from examples or docs (white-label is the paid roadmap, not a free option).

## Code of conduct

Be kind. Doxa is a Christian project; the most basic ethic of the room is "love your neighbour as yourself" (Mark 12:31). Disagreement is welcome — meanness, contempt, and trolling are not.

## License

By contributing to this repo (schemas, docs, examples), you agree your contribution is MIT licensed. The hosted server, system prompt, and brand voice are © Doxa and not covered by the repo's MIT license.
