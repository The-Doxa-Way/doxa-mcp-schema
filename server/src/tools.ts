/**
 * Tool definitions advertised by the Doxa MCP server.
 *
 * These mirror, verbatim, what the hosted endpoint (https://doxa.app/mcp/v1)
 * returns from `tools/list`. They are embedded here so introspection works
 * offline and deterministically; tool *execution* is forwarded to the hosted
 * endpoint (see index.ts). Regenerate with `npm run sync-tools`.
 */

import type { Tool } from '@modelcontextprotocol/sdk/types.js';

export const TOOLS: Tool[] = [
  {
    "name": "doxa_encourage",
    "description": "Generate Christian encouragement in the Doxa voice for the situation a user describes. Returns a short, screenshot-shareable response anchored in Scripture (Berean Standard Bible), tagged to one of the nine movements of The Doxa Way journey map: hear, discern, test, record, remember, engage, trust, fight, endure. No anthropomorphism, no AI companion framing.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "situation": {
          "type": "string",
          "description": "Describe what the user is facing in 1-3 sentences.",
          "maxLength": 2000
        },
        "movement": {
          "type": "string",
          "enum": [
            "hear",
            "discern",
            "test",
            "record",
            "remember",
            "engage",
            "trust",
            "fight",
            "endure"
          ],
          "description": "Optional. Which movement of The Doxa Way fits: hear, discern, test, record, remember, engage, trust, fight, or endure. If absent, server infers."
        }
      },
      "required": [
        "situation"
      ]
    }
  },
  {
    "name": "doxa_scripture",
    "description": "Look up a Bible verse and return the Scripture text with a deep link to its Doxa Bible page. Defaults to the Berean Standard Bible (BSB, public domain Bible translation). Use for any Christian, biblical, Scripture, verse lookup, or devotional citation task where a clickable verse link matters. Reference format: \"John 14:6\" or \"Psalm 23:1-3\".",
    "inputSchema": {
      "type": "object",
      "properties": {
        "reference": {
          "type": "string",
          "description": "Verse reference, e.g., \"John 14:6\"",
          "maxLength": 100
        }
      },
      "required": [
        "reference"
      ]
    }
  },
  {
    "name": "doxa_way_movement",
    "description": "Get the nine movements of The Doxa Way, a biblical Christian discipleship framework: Hear, Discern, Test, Record, Remember, Engage, Trust, Fight, Endure. Use for faith journey mapping, Bible-grounded spiritual growth, or Christian encouragement context. Returns all nine movements, or one if specified.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "movement": {
          "type": "string",
          "enum": [
            "hear",
            "discern",
            "test",
            "record",
            "remember",
            "engage",
            "trust",
            "fight",
            "endure"
          ],
          "description": "Optional. Get a single movement by id. If absent, returns all 9."
        }
      }
    }
  }
] as unknown as Tool[];
