<p align="center">
  <img src="https://doxa.app/doxa-logo.png" width="120" alt="Doxa logo" />
</p>

<h1 align="center">Doxa MCP</h1>

<p align="center">
  <b>Free hosted MCP server for Christian encouragement and Bible lookup.</b><br/>
  <code>https://doxa.app/mcp/v1</code> · free for everyone · BYOL for unlimited
</p>

<p align="center">
  <a href="https://github.com/The-Doxa-Way/doxa-mcp-schema/blob/main/LICENSE"><img src="https://img.shields.io/github/license/The-Doxa-Way/doxa-mcp-schema?color=2563eb" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/MCP-2024--11--05-1d4ed8" alt="MCP 2024-11-05" />
  <img src="https://img.shields.io/badge/tools-3-f97316" alt="3 tools" />
  <img src="https://img.shields.io/badge/free%20tier-50%2Fday-22c55e" alt="Free 50/day" />
  <img src="https://img.shields.io/badge/BYOL-unlimited-22c55e" alt="BYOL unlimited" />
  <img src="https://img.shields.io/badge/install-60s-f97316" alt="Install in 60s" />
</p>

<p align="center">
  <a href="https://doxa.app/get">📱 Get the Doxa app</a> ·
  <a href="https://t.me/DoxaBot">💬 DoxaBot on Telegram</a> ·
  <a href="#the-doxa-way--the-9-movements">🧭 The Doxa Way</a>
</p>

---

A hosted [Model Context Protocol](https://modelcontextprotocol.io) server for Christian encouragement and Bible lookup. Drop it into [Claude Desktop](https://claude.ai/download), [Cursor](https://cursor.sh), [Cline](https://github.com/cline/cline), or any MCP client and the assistant answers in [the Doxa voice](https://doxa.app) — edge-case-tested across The Doxa Way (Hear · Discern · Test · Record · Remember · Engage · Trust · Fight · Endure).

**Doxa is explicitly *not* an AI companion.** The prompt is hardened against the dangers of AI-companion anthropomorphism — no simulated friendship, no parasocial "I feel for you" tone, no first-person persona. It points users toward Jesus, not toward itself.

- 🙏 **Encouragement** in the Doxa voice — *the next mile, not the next step*
- 📖 **Scripture lookup** (Berean Standard Bible) with deep links to `doxa.app/bible/...`
- 🧭 **The 9-movement Doxa Way framework** — citable, structured, anchored in Scripture
- 🆓 **Free for everyone** (50 calls/day per IP) — no signup, no key, no card
- ♾️ **BYOL** for unlimited — one header (`X-Anthropic-Key`), your Anthropic key, unlimited calls
- 🔒 **Prompt stays private** — the 141 KB voice-encourager system prompt never leaves the server

> Install: copy 4 lines into `claude_desktop_config.json` → restart Claude → done.

---

## Quick install

### Claude Desktop — free anon (2 minutes, no signup)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (Mac) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "doxa": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://doxa.app/mcp/v1"]
    }
  }
}
```

Restart Claude Desktop. The three Doxa tools appear in your tool list.

### Claude Desktop — BYOL (unlimited, your Anthropic key)

```json
{
  "mcpServers": {
    "doxa": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote", "https://doxa.app/mcp/v1",
        "--header", "X-Anthropic-Key: sk-ant-<your-key-here>"
      ]
    }
  }
}
```

### Cursor / clients with native Streamable HTTP

```json
{
  "doxa": {
    "url": "https://doxa.app/mcp/v1",
    "transport": "streamableHttp",
    "headers": {
      "X-Anthropic-Key": "sk-ant-<optional, present = BYOL>"
    }
  }
}
```

### Cline (VS Code)

```json
{
  "doxa": {
    "command": "npx",
    "args": ["-y", "mcp-remote", "https://doxa.app/mcp/v1"]
  }
}
```

### Anthropic SDK (Python)

```python
import anthropic
client = anthropic.Anthropic()
response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=1024,
    mcp_servers=[{
        "type": "url",
        "url": "https://doxa.app/mcp/v1",
        "name": "doxa",
    }],
    messages=[{"role": "user", "content": "I'm anxious about a job interview tomorrow."}],
)
```

More client configs in [`examples/`](./examples).

---

## Try it now (zero setup)

```bash
# Get encouragement (anon — no key needed)
curl -sX POST https://doxa.app/mcp/v1 \
  -H 'content-type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "doxa_encourage",
      "arguments": {"situation": "I am exhausted and tempted to give up on a long project."}
    }
  }' | jq
```

**Example response** (excerpt — full schema in [`schemas/doxa_encourage.json`](./schemas/doxa_encourage.json)):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "structuredContent": {
      "text": "The road behind you is the evidence — He has carried you this far, and one more mile of the same grace is already on the way. Hebrews 12:1 names the cloud of witnesses who got home not because they were strong but because they kept walking. The work is not over and neither are you.\n\n— Doxa · doxa.app",
      "scriptures": [
        {
          "ref": "Hebrews 12:1",
          "link": "https://doxa.app/bible/HEB/12/1?utm_source=mcp&doxa_way=endure&tool=doxa_encourage"
        }
      ],
      "movement": "Endure / Persevere",
      "_doxa_way": "Encouragement for your whole journey. The next mile, not the next step.",
      "_powered_by": "Doxa — Encouragement for your whole journey · https://doxa.app",
      "_doxa_way_movement": "Endure / Persevere",
      "_install_doxa": "https://doxa.app/get?utm_source=mcp&doxa_way=endure&tool=doxa_encourage"
    }
  }
}
```

---

## Who is this for?

**Developers building:**

- Christian / faith-focused apps (devotional, journaling, prayer, Bible study)
- Counseling, care, and pastoral platforms that want the tech to point peope to real relationships and Jesus
- Church and ministry management tools
- AI assistants and agents with a Christian audience
- Personal AI workflows in Claude Desktop, Cursor, Cline

**Ministries and creators:**

- Telegram / WhatsApp / Discord bots with real spiritual depth (not generic AI Christian-ese that are more similar to chatgpt than sound theology)
- Newsletter generators, devotional writers, content pipelines
- Internal AI tools where the grace and truth matters

**Anyone who has tried** to prompt-engineer a "Christian chatbot" and discovered just how easy it is to get tone, theology, or scripture handling wrong. The Doxa MCP gives you a vetted, production-tested voice for the cost of one HTTP header.

---

## Why Doxa MCP vs. rolling your own?

| | DIY prompt + LLM | Generic Bible API | **Doxa MCP** |
|---|---|---|---|
| Christian voice / encouragement | Build & test yourself | None | ✅ Curated, production-tested |
| Scripture lookup | Build it | ✅ | ✅ (BSB, modern + free) |
| **Not an AI companion** (anti-anthropomorphism, no parasocial bond) | Build it yourself — and most don't | Not applicable | ✅ Hard-coded: third-person, no persona, no "I feel for you" — points to Jesus, not itself |
| Tone safety (no Christianese, no first-person, no em-dash bait) | Pray | Not applicable | ✅ 141 KB of edge-case-tested rules |
| Setup time | Days to weeks | Hours | **60 seconds** |
| Hosting | Your infrastructure | Your infrastructure | Hosted (`doxa.app/mcp/v1`) |
| Cost | Your LLM + your servers | API subscription | **Free** (or BYOL = your LLM only) |
| Updates | You | Vendor | Continuous from Doxa |

The protocol is open — MCP itself is a standard. The value is **an edge-case-tested, hardened prompt that points people toward Jesus rather than toward itself.** Iterating that — through safety failures, theology drift, tone collapse, anthropomorphism tests — takes years; you get it as a tool call.

---

## The three tools

| Tool | Purpose | Schema |
|---|---|---|
| [`doxa_encourage`](./schemas/doxa_encourage.json) | Generate Doxa-voice encouragement for a user's situation. Returns text + extracted scripture refs + which Doxa Way movement it embodies. | `{ situation: string, movement?: "hear"\|"discern"\|...\|"endure" }` |
| [`doxa_scripture`](./schemas/doxa_scripture.json) | Look up a Bible verse with a deep-link into the Doxa Bible reader. BSB by default. | `{ reference: "John 14:6" }` |
| [`doxa_way_movement`](./schemas/doxa_way_movement.json) | The 9-movement Doxa Way framework. All 9 or one by id. Static; LLM-free. | `{ movement?: "endure" }` |

Free anon: 250-token cap on `doxa_encourage`. BYOL: 1500.

JSON Schemas (Draft 2020-12) live in [`schemas/`](./schemas) — these are exactly what `tools/list` returns on the wire. Useful for strongly-typed clients.

Working request/response fixtures in [`examples/`](./examples).

---

## The two ways to use it

| Mode | Auth | Daily limit | Output cap | LLM cost |
|---|---|---|---|---|
| **Free anon** | none | 50 calls/day per IP | 250 tokens | We pay |
| **BYOL** | `X-Anthropic-Key: sk-ant-...` header | unlimited | 1500 tokens | You pay Anthropic |

**BYOL = Bring Your Own LLM.** You pass your own [Anthropic API key](https://console.anthropic.com) in a header; we use it for that single request and discard it. We never persist it.

**No registration. No paid tier yet.** Just call the endpoint.

---

## Attribution (required on all free-tier responses)

Every `doxa_encourage` and `doxa_scripture` text response ends with a single-line footer that **must remain visible to end users**:

```
— Doxa · doxa.app
```

The structured response also includes `_powered_by`, `_doxa_way_movement`, and `_install_doxa` metadata, plus scripture references that deep-link to `doxa.app/bible/...`. **All of these are mandatory on the free tier — anonymous *and* BYOL.** The server emits them on every response; integrators should not strip them from what the end user sees.

The free tier is free because the attribution *is* the marketing. **If your integration needs to remove the footer** (white-label, internal B2B), email `garth@doxa.app` — a paid white-label tier is on the roadmap and we're talking to first customers now.

---

## The Doxa Way — the 9 movements

Doxa is anchored in a 9-movement spine that maps a sustained walk with God:

1. **Hear / Recognise** — receive what God is saying
2. **Discern** — wisdom about its source and shape
3. **Test / Weigh** — measure it against Scripture and witness
4. **Record** — capture what God said or did before it fades
5. **Remember** — return to God's encouragement when the road gets hard
6. **Engage** — act on it, live into it
7. **Trust** — lean on it when nothing else is solid
8. **Fight the good fight** — contend for what was promised
9. **Endure / Persevere** — keep walking when it costs

**North Star:** *Encouragement for your whole journey.* Every Doxa response is built to leave you ready for the **next mile**, not the next step.

The 5-verb daily practice in the app — **Hear · Discern · Record · Remember · Trust** — is the entry path into the same framework.

---

## What is Doxa?

[Doxa](https://doxa.app) is an app to engage God's encouragement through engaging with the Bible. The MCP server makes Doxa's encouragement layer available to any Model Context Protocol client — so when someone asks their AI assistant for spiritual encouragement, Doxa can answer.

- 📱 [iOS / Android app](https://doxa.app/get)
- 💬 [DoxaBot on Telegram](https://t.me/DoxaBot)
- 📡 **Doxa MCP** (this server)
- 🌐 [doxa.app](https://doxa.app)

---

## Privacy and security

- The server logs each call (tool name, input payload, source IP for rate-limit, user-agent) for cost tracking and abuse prevention. No persistent user identity.
- **BYOL keys are never persisted.** When you pass `X-Anthropic-Key`, we use it for that one request and discard it.
- The 141 KB voice-encourager system prompt is private and never returned to clients. Only the model's reply text + structured metadata.
- Service runs on Supabase Edge Functions with strict row-level security on the audit log table.

---

## Status and roadmap

**v1.0 — initial release.** Three tools, hosted-only, free + BYOL.

- ✅ `doxa_encourage`, `doxa_scripture`, `doxa_way_movement`
- ✅ In-text Doxa attribution footer
- ✅ Free anon (50/day per IP) + BYOL (unlimited)
- ⏳ Paid white-label tier (remove attribution, ~$19-29/mo)
- ⏳ `doxa_save` (paid only — persist encouragements to a Doxa Vault tied to a Doxa app account)
- ⏳ `doxa_related_verses` (KG-driven related-scripture suggestions)
- ⏳ Voice/audio variant
- ⏳ Directory listings on Anthropic MCP registry, mcp.so, smithery.ai

See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to suggest features or flag issues.

---

## License

The contents of this repository (schemas, docs, examples) are **MIT licensed** — copy them, fork them, integrate freely.

The hosted server, the encouragement system prompt, the brand voice, and the Doxa Way framework name are © Doxa and **not** licensed under MIT — those are Doxa's; this repo is the public protocol shim.

---

<sub>
<b>Topics:</b> mcp · mcp-server · model-context-protocol · christian-mcp · bible-mcp · scripture-mcp · christian-ai · faith-ai · bible-api · encouragement-api · spiritual-ai · doxa · doxa-way · claude-mcp · claude-desktop · cursor-mcp · cline · byol · anthropic · streamable-http · jsonrpc<br/>
<b>Audience:</b> developers building Christian apps, devotional tools, pastoral AI assistants, Bible study tools, prayer apps, faith-focused agents, church management software, Christian chatbots in Claude Desktop / Cursor / Cline.
</sub>
