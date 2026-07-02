# @thedoxaway/mcp-server

A local, self-hostable **MCP stdio server** for [Doxa](https://doxa.app) — a Christian AI for any question, in any season.

It speaks the Model Context Protocol locally over stdio (`initialize` / `tools/list` / `tools/call`) and forwards tool *execution* to the hosted Doxa endpoint (`https://doxa.app/mcp/v1`), exactly like any API-backed MCP server. `tools/list` is served from embedded definitions, so introspection works with no network and no credentials.

Nothing about Doxa's model changes: every tool call still routes through `doxa.app`, which enforces the free per-caller quota (or BYOL) and appends the attribution footer. This is a protocol adapter, not a reimplementation.

> **Most integrations don't need this.** The simplest way to use Doxa is the hosted endpoint via `mcp-remote` — see the [root README](../README.md). Reach for this package when your MCP host runs the server as a local process (stdio) rather than connecting to a remote URL.

## Tools

| Tool | What it does |
| --- | --- |
| `doxa_encourage` | Encouragement for a situation, anchored in Scripture and real testimonies. |
| `doxa_scripture` | Bible verse lookup (Berean Standard Bible) with a deep link into the Doxa reader. |
| `doxa_way_movement` | The Doxa Way journey map. All 9 movements or one by id. Static, no LLM call. |

## Use it

```json
{
  "mcpServers": {
    "doxa": {
      "command": "npx",
      "args": ["-y", "@thedoxaway/mcp-server"]
    }
  }
}
```

## Configuration

All optional, via environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DOXA_MCP_ENDPOINT` | `https://doxa.app/mcp/v1` | Override the hosted endpoint. |
| `ANTHROPIC_API_KEY` | — | BYOL: unlimited calls, you pay Anthropic. Forwarded as `x-anthropic-key`. |
| `DOXA_CALLER_ID` | — | Per-user attribution for fair free-tier counting. Format: `<surface>:<id>`. |

## Develop

```bash
npm install
npm run build        # tsc -> dist/
npm start            # run the stdio server
npm run sync-tools   # regenerate src/tools.ts from the live endpoint
```

MIT licensed. Part of [doxa-mcp-schema](https://github.com/The-Doxa-Way/doxa-mcp-schema).
