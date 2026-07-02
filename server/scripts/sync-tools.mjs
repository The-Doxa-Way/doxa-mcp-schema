#!/usr/bin/env node
/**
 * Regenerate src/tools.ts from the live hosted endpoint's tools/list response,
 * so the embedded introspection definitions never drift from production.
 *
 *   node scripts/sync-tools.mjs
 *   DOXA_MCP_ENDPOINT=https://staging.doxa.app/mcp/v1 node scripts/sync-tools.mjs
 */

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const endpoint = process.env.DOXA_MCP_ENDPOINT ?? 'https://doxa.app/mcp/v1';
const outFile = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'tools.ts');

const res = await fetch(endpoint, {
  method: 'POST',
  headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
  body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }),
});
if (!res.ok) throw new Error(`tools/list failed: HTTP ${res.status}`);
const json = await res.json();
const tools = json.result?.tools;
if (!Array.isArray(tools) || tools.length === 0) throw new Error('No tools returned');

const body = JSON.stringify(tools, null, 2);
const ts = `/**
 * Tool definitions advertised by the Doxa MCP server.
 *
 * These mirror, verbatim, what the hosted endpoint (${endpoint})
 * returns from \`tools/list\`. They are embedded here so introspection works
 * offline and deterministically; tool *execution* is forwarded to the hosted
 * endpoint (see index.ts). Regenerate with \`npm run sync-tools\`.
 */

import type { Tool } from '@modelcontextprotocol/sdk/types.js';

export const TOOLS: Tool[] = ${body} as unknown as Tool[];
`;

writeFileSync(outFile, ts);
console.error(`Wrote ${outFile} with ${tools.length} tools: ${tools.map((t) => t.name).join(', ')}`);
