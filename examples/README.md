# Examples

Real request / response fixtures for the Doxa MCP server at `https://mcp.doxa.app/v1`. Use as references for client implementations or as test fixtures.

## Tool fixtures

| Tool | Request | Response |
|---|---|---|
| `doxa_encourage` | [request](./doxa_encourage.request.json) | [response](./doxa_encourage.response.json) |
| `doxa_scripture` | [request](./doxa_scripture.request.json) | [response](./doxa_scripture.response.json) |
| `doxa_way_movement` | [request](./doxa_way_movement.request.json) | [response](./doxa_way_movement.response.json) |

Response fixtures include both `content[0].text` (JSON-stringified for max client compat) and `structuredContent` (typed payload for modern clients).

## Client configs

| Client | File |
|---|---|
| Claude Desktop (Mac / Windows) | [`claude_desktop_config.example.json`](./claude_desktop_config.example.json) |
| Cursor | [`cursor_mcp.example.json`](./cursor_mcp.example.json) |

Both show free-anon and BYOL variants.

## Sanity-check a fixture against the live server

```bash
curl -sX POST https://mcp.doxa.app/v1 \
  -H 'content-type: application/json' \
  --data @doxa_encourage.request.json | jq
```

The response will closely match `doxa_encourage.response.json` — exact wording varies (the model is non-deterministic), but the shape and structured-content keys are stable.
