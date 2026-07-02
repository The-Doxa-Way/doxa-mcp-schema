#!/usr/bin/env node
/**
 * @thedoxaway/mcp-server
 *
 * A local, self-hostable MCP stdio server for Doxa. It speaks the Model Context
 * Protocol locally (initialize / tools/list / tools/call over stdio) and forwards
 * tool *execution* to the hosted Doxa endpoint (https://doxa.app/mcp/v1) over HTTP,
 * exactly like any API-backed MCP server.
 *
 * Why this exists alongside the hosted endpoint:
 *   - Some MCP hosts (and directory build checks) run the server locally and
 *     introspect it. This gives them a real local process to build and start.
 *   - `tools/list` is served from embedded definitions, so introspection works
 *     with no network and no credentials.
 *
 * Nothing about Doxa's model changes: every tool call still routes through
 * doxa.app, which enforces the free per-caller quota (or BYOL) and appends the
 * attribution footer. This is a protocol adapter, not a reimplementation.
 *
 * Config (all optional, via environment):
 *   DOXA_MCP_ENDPOINT   Override the endpoint. Defaults to https://doxa.app/mcp/v1.
 *   ANTHROPIC_API_KEY   BYOL: unlimited calls, you pay Anthropic. Forwarded as x-anthropic-key.
 *   DOXA_CALLER_ID      Per-user attribution for fair free-tier counting. Format: `<surface>:<id>`.
 */

// The low-level `Server` (not the high-level `McpServer`) is used deliberately:
// it lets us advertise the hosted endpoint's exact JSON-Schema tool definitions
// verbatim (see tools.ts), which the Zod-based high-level API cannot express
// without a lossy conversion. The SDK sanctions `Server` for this advanced case.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
} from '@modelcontextprotocol/sdk/types.js';
import { TOOLS } from './tools.js';

const DEFAULT_ENDPOINT = 'https://doxa.app/mcp/v1';
const NAME = 'doxa-mcp';
const VERSION = '0.1.0';

const endpoint = process.env.DOXA_MCP_ENDPOINT ?? DEFAULT_ENDPOINT;
const anthropicKey = process.env.ANTHROPIC_API_KEY?.trim();
const callerId = process.env.DOXA_CALLER_ID?.trim();

const server = new Server(
  { name: NAME, version: VERSION },
  { capabilities: { tools: {} } },
);

// Introspection is served locally from embedded definitions — no network needed.
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

// Execution is forwarded to the hosted Doxa endpoint.
server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CallToolResult> => {
  const { name, arguments: args } = request.params;

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'user-agent': `${NAME}-server/${VERSION}`,
  };
  if (anthropicKey) headers['x-anthropic-key'] = anthropicKey;
  if (callerId) headers['x-doxa-caller-id'] = callerId;

  const res = await fetch(endpoint, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name, arguments: args ?? {} },
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    return {
      content: [{ type: 'text', text: `Doxa endpoint error: HTTP ${res.status}: ${body.slice(0, 300)}` }],
      isError: true,
    };
  }

  const json = (await res.json()) as {
    error?: { message?: string };
    result?: CallToolResult;
  };

  if (json.error) {
    return {
      content: [{ type: 'text', text: json.error.message ?? 'Doxa tool error' }],
      isError: true,
    };
  }
  if (!json.result) {
    return { content: [{ type: 'text', text: 'Empty response from Doxa endpoint' }], isError: true };
  }
  // The hosted endpoint already returns a well-formed CallToolResult (content + isError),
  // including the rate-limit case, so pass it through unchanged.
  return json.result;
});

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Stderr only — stdout is the MCP transport and must stay clean.
  process.stderr.write(`${NAME}-server ${VERSION} ready (endpoint: ${endpoint})\n`);
}

main().catch((err) => {
  process.stderr.write(`Fatal: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`);
  process.exit(1);
});
