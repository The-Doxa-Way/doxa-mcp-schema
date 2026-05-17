# Publishing Doxa MCP to the registries

Three places to list Doxa MCP for discoverability. All are one-time submissions; updates after that are version-bumps in `server.json`.

## 1. Official MCP Registry (`registry.modelcontextprotocol.io`)

The authoritative registry. AI agents and clients will increasingly discover servers via this index, so this is the highest-priority listing.

**Descriptor**: [`server.json`](./server.json) in this repo — already prepared.

**Steps** (5 min, interactive GitHub OAuth):

```bash
# 1. Install the publisher CLI (one-time)
curl -sL https://github.com/modelcontextprotocol/registry/releases/latest/download/mcp-publisher_darwin_arm64.tar.gz \
  | tar -xz -C /tmp
sudo mv /tmp/mcp-publisher /usr/local/bin/

# 2. Authenticate via GitHub OAuth (opens browser; sign in as a member of The-Doxa-Way org)
mcp-publisher login

# 3. Publish (from the doxa-mcp-schema repo root)
cd ~/Documents/Projects/doxa-mcp-schema
mcp-publisher publish

# 4. Verify
open https://registry.modelcontextprotocol.io
# Search for "doxa" — the listing should appear within a minute
```

**Namespace**: `io.github.TheDoxaWay/doxa-mcp` — note the namespace strips the hyphens that appear in the GitHub URL (`The-Doxa-Way`). The MCP Registry recognises the org as `TheDoxaWay`. GitHub OAuth must succeed as an org member for the registry to accept this name.

**Updates later**: bump `version` in `server.json`, run `mcp-publisher publish` again.

---

## 2. Smithery.ai

Popular community directory + CLI hub. Some MCP clients (including Smithery's own) use this as their discovery source.

**Steps**:

```bash
# 1. Install Smithery CLI
npm install -g @smithery/cli

# 2. Authenticate
smithery login

# 3. Publish the hosted URL
smithery mcp publish https://doxa.app/mcp/v1 \
  --name "The-Doxa-Way/doxa-mcp" \
  --description "Christian encouragement and Bible lookup for any AI assistant. Free, hosted, BYOL for unlimited."

# 4. Verify
open https://smithery.ai/server/The-Doxa-Way/doxa-mcp
```

---

## 3. mcp.so

Community directory with strong SEO. Heaviest organic-search traffic for "MCP server" + topic queries.

**Steps** (web form, no CLI):

1. Open <https://mcp.so/submit> (or whichever current submission URL the homepage links to)
2. Sign in (likely GitHub OAuth)
3. Fill in:
   - **Name**: Doxa MCP
   - **Description**: Use the `description` field from `server.json` above (~340 chars)
   - **URL**: `https://doxa.app/mcp/v1`
   - **GitHub**: `https://github.com/The-Doxa-Way/doxa-mcp-schema`
   - **Website**: `https://doxa.app/mcp`
   - **Tags**: `christian`, `bible`, `scripture`, `encouragement`, `byol`, `streamable-http`
   - **Type**: Remote / Hosted (Streamable HTTP)
4. Submit; approval is usually < 24h.

---

## Each release after v1

When the API changes meaningfully (new tool, breaking change to an existing tool, schema field added):

1. Bump `version` in `server.json` (semver — patch for tweaks, minor for new tools, major for breaking changes).
2. Update the public schemas in `schemas/` and example fixtures in `examples/` to match the live server.
3. `mcp-publisher publish` again (the registry tracks version history).
4. Open an issue or DM the Smithery / mcp.so curators if a major version changes the install snippet.

---

## What gets published vs. stays private

| | Public | Private |
|---|---|---|
| `server.json` (this repo) | ✅ | |
| JSON schemas + examples (this repo) | ✅ | |
| README + install snippets | ✅ | |
| `doxa.app/mcp` landing page | ✅ | |
| The voice-encourager system prompt (141 KB) | | ✅ (Supabase) |
| Edge function source | | ✅ (private repo) |
| `mcp_calls` audit log | | ✅ (Supabase RLS) |

The registries only see what's in `server.json` + the public schema repo. The prompt, the implementation, and the audit log stay server-side.
