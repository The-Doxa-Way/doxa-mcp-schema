# @thedoxaway/mcp-client

Tiny TypeScript client for [Doxa MCP](https://doxa.app/mcp). Free hosted, BYOL for unlimited.

Zero runtime dependencies. Node 18+ (native `fetch`).

```bash
npm install @thedoxaway/mcp-client
```

## What is Doxa MCP?

A free hosted [Model Context Protocol](https://modelcontextprotocol.io) server for Christian encouragement and Bible lookup. Drop it into any MCP client (Claude Desktop, Cursor, Cline) or call it directly from your own agent code.

**Three tools:**

- `encourage(situation)` — Doxa-voice encouragement for a user's situation
- `scripture(reference)` — Bible verse lookup (Berean Standard Bible) with a deep-link
- `wayMovement(id?)` — The 9-movement Doxa Way framework

**Two tiers:**

- **Free anon** — 50 calls/day per IP, 250-token output cap. No signup, no card.
- **BYOL** — pass your own Anthropic key in `anthropicKey`. Unlimited calls, 1500-token cap.

## Quick start

```typescript
import { DoxaClient } from '@thedoxaway/mcp-client';

// Free anon (default)
const doxa = new DoxaClient();

const reply = await doxa.encourage('I am exhausted and tempted to give up.');
console.log(reply.text);
//  "The road behind you is the evidence — He has carried you this far,
//   and one more mile of the same grace is already on the way. ..."
console.log(reply.movement);     // "Endure / Persevere"
console.log(reply.scriptures);   // [{ ref: "Hebrews 12:1", link: "..." }]
console.log(reply.quota);
//  { tier: 'free', used: 1, limit: 50, window_seconds: 86400 }
```

## BYOL (unlimited)

Pass your own [Anthropic API key](https://console.anthropic.com) and the server uses it for the call. We never persist it.

```typescript
const doxa = new DoxaClient({
  anthropicKey: process.env.ANTHROPIC_API_KEY,
});

const reply = await doxa.encourage('...');
console.log(reply.quota);
//  { tier: 'byol', used: 0, limit: -1, window_seconds: 86400 }
```

## API

### `new DoxaClient(options?)`

| Option | Type | Default | Description |
|---|---|---|---|
| `endpoint` | `string` | `https://doxa.app/mcp/v1` | MCP endpoint URL |
| `anthropicKey` | `string` | none | Your Anthropic key (switches to BYOL mode) |
| `userAgent` | `string` | `@thedoxaway/mcp-client` | Override the user-agent header |
| `fetch` | `typeof fetch` | global `fetch` | Custom fetch implementation |

### `encourage(situation, movement?)`

```typescript
const result = await doxa.encourage(
  'I am exhausted and tempted to give up.',
  'endure',  // optional — hint which movement fits
);
```

Returns:

```typescript
{
  text: string;                              // encouragement, ends with footer
  scriptures: { ref: string; link: string }[];  // refs extracted from text
  movement: string;                          // name of the embodied movement
  doxaWay: string;                           // north star: "Encouragement for your whole journey..."
  quota: DoxaQuota;
}
```

### `scripture(reference)`

```typescript
const verse = await doxa.scripture('John 14:6');
```

Returns:

```typescript
{
  reference: string;          // "John 14:6"
  text: string;               // verse text (BSB)
  translation: 'BSB';
  link: string;               // https://doxa.app/bible/JHN/14/6?...
  related: ScriptureRef[];    // currently always [] (populated in a future version)
  quota: DoxaQuota;
}
```

### `wayMovement(id?)`

```typescript
const all = await doxa.wayMovement();                // all 9 movements
const one = await doxa.wayMovement('endure');        // single movement
```

The 9 movement ids: `hear`, `discern`, `test`, `record`, `remember`, `engage`, `trust`, `fight`, `endure`.

## Error handling

```typescript
import { DoxaClient, DoxaError, DoxaRateLimitError } from '@thedoxaway/mcp-client';

try {
  await doxa.encourage('...');
} catch (err) {
  if (err instanceof DoxaRateLimitError) {
    console.log('Hit the free tier limit');
    console.log('Upgrade:', err.byolUrl);
    console.log('Quota:', err.quota);
  } else if (err instanceof DoxaError) {
    console.log('Doxa MCP error:', err.code, err.message);
  } else {
    throw err;  // not a Doxa error
  }
}
```

## Quota metadata

Every response includes `quota` so you can build rate-limit UIs without polling:

```typescript
const reply = await doxa.encourage('...');

if (reply.quota.tier === 'free' && reply.quota.used >= reply.quota.limit - 5) {
  console.warn(`Only ${reply.quota.limit - reply.quota.used} calls left in this 24h window`);
}
```

## Attribution (mandatory on free tier)

The `text` field on free-tier `encourage` and `scripture` responses ends with a one-line footer:

```
— Doxa · doxa.app
```

Keep this visible to your end user. The footer is how people find Doxa. If your integration needs to remove it (white-label, internal B2B), email `garth@doxa.app` — a paid white-label tier is on the roadmap.

## Privacy and security

- The hosted server logs each call (tool name, input, source IP, user-agent) for cost tracking and abuse prevention. No persistent user identity.
- **BYOL keys are never persisted.** When you pass `anthropicKey`, the server uses it for that one request and discards it.
- The 141 KB voice-encourager system prompt is private to the server. Only the model's reply text + structured metadata reach clients.

Full terms: [doxa.app/mcp/terms](https://doxa.app/mcp/terms). Report abuse: [abuse@doxa.app](mailto:abuse@doxa.app). Security disclosures: [security@doxa.app](mailto:security@doxa.app).

## Try it without installing

```bash
curl -sX POST https://doxa.app/mcp/v1 \
  -H 'content-type: application/json' \
  -H 'user-agent: doxa-test' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "doxa_encourage",
      "arguments": {"situation": "I am exhausted and tempted to give up."}
    }
  }' | jq -r '.result.structuredContent.text'
```

## License

MIT. See [LICENSE](./LICENSE) in this directory, or [the top-level LICENSE](../../LICENSE) of the doxa-mcp-schema repo. The hosted server, the encouragement system prompt, and the name "The Doxa Way" are © Doxa.

## Related

- **Server** — [github.com/The-Doxa-Way/doxa-mcp-schema](https://github.com/The-Doxa-Way/doxa-mcp-schema)
- **Doxa app** — [doxa.app](https://doxa.app)
- **DoxaBot on Telegram** — [t.me/TheDoxaWayBot](https://t.me/TheDoxaWayBot)
