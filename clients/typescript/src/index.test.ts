/**
 * Integration-style smoke test for @thedoxaway/mcp-client.
 *
 * Hits the live MCP at doxa.app/mcp/v1 via free anon tier. 3 calls total,
 * which fits comfortably in the 50/day quota. Run with:
 *
 *   node --test --experimental-strip-types src/index.test.ts
 *
 * Set DOXA_MCP_ENDPOINT to override (e.g. for local testing).
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DoxaClient, DoxaError } from './index.ts';

const endpoint = process.env.DOXA_MCP_ENDPOINT ?? 'https://doxa.app/mcp/v1';

test('encourage returns text + scriptures + quota', async () => {
  const doxa = new DoxaClient({ endpoint });
  const result = await doxa.encourage('I am exhausted and tempted to give up on a long project.');
  assert.ok(result.text.length > 50, 'response text should be substantial');
  assert.ok(result.text.includes('Doxa'), 'response should include attribution footer');
  assert.equal(typeof result.movement, 'string');
  assert.ok(['free', 'byol'].includes(result.quota.tier));
  assert.equal(result.quota.window_seconds, 86400);
  assert.ok(Array.isArray(result.scriptures));
});

test('scripture returns verse text + link + quota', async () => {
  const doxa = new DoxaClient({ endpoint });
  const result = await doxa.scripture('John 14:6');
  assert.equal(result.reference, 'John 14:6');
  assert.ok(result.text.length > 10, 'verse text should be non-empty');
  assert.ok(result.link.startsWith('https://doxa.app/bible/'));
  assert.equal(result.translation, 'BSB');
  assert.ok(['free', 'byol'].includes(result.quota.tier));
});

test('wayMovement (all) returns 9 movements', async () => {
  const doxa = new DoxaClient({ endpoint });
  const result = await doxa.wayMovement();
  assert.equal(result.movements.length, 9);
  assert.ok(result.northStar.length > 0);
  assert.equal(result.fiveVerbDailyPractice.length, 5);
});

test('wayMovement (one) returns single movement', async () => {
  const doxa = new DoxaClient({ endpoint });
  const result = await doxa.wayMovement('endure');
  assert.equal(result.movement.id, 'endure');
  assert.ok(result.movement.name.toLowerCase().includes('endure'));
});

test('DoxaError thrown for invalid tool args', async () => {
  const doxa = new DoxaClient({ endpoint });
  await assert.rejects(
    () => doxa.scripture(''),
    (err: unknown) => err instanceof DoxaError && err.code === -32602,
  );
});
