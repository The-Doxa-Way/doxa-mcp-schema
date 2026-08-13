// merge-resolve.test.js — exercises the mergeResolve() CLI command directly
// (review 2026-08-13: check-kg-merge-integrity.test.js only tested the
// DETECTOR; the RESOLVER — the tool an operator actually runs to fix a
// flagged conflict, and the one that WRITES state — had no coverage at all).
//
// knowledge-graph-merkle.js resolves its target files via __dirname (always
// the SCRIPT's own directory, never the caller's cwd), so this cannot be
// require()'d directly against the real repo without risking a write to this
// repo's own .knowledge-graph-merkle.json. Instead, each test copies the
// real script + its two runtime dependencies (kg-index.js, lib/atomic.js)
// into a fresh temp directory and invokes it as a subprocess there — a
// real, isolated integration test, not a mock.
//
// Run: node --test scripts/merge-resolve.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REAL_SCRIPTS_DIR = __dirname;

/** Sets up an isolated temp "repo" with its own scripts/ + .knowledge-graph/. */
function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mrg-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, '.knowledge-graph'), { recursive: true });
  for (const f of ['knowledge-graph-merkle.js', 'kg-index.js']) {
    fs.copyFileSync(path.join(REAL_SCRIPTS_DIR, f), path.join(root, 'scripts', f));
  }
  fs.copyFileSync(
    path.join(REAL_SCRIPTS_DIR, 'lib', 'atomic.js'),
    path.join(root, 'scripts', 'lib', 'atomic.js')
  );
  fs.writeFileSync(path.join(root, '.knowledge-graph', 'graph.json'), JSON.stringify({ entities: [], relations: [] }));
  return root;
}

function obs(hash, entityName, timestamp) {
  return {
    hash,
    entityName,
    content: entityName,
    provenance: { sourceFile: 'f.md', lineNumber: 1 },
    timestamp: timestamp || '2026-01-01T00:00:00.000Z',
  };
}

function writeFixture(root, name, observations) {
  const p = path.join(root, name);
  fs.writeFileSync(p, JSON.stringify({ merkleRoot: 'x', observations, lastVerified: null, version: 1 }, null, 2));
  return p;
}

function runMergeResolve(root, oursPath, theirsPath) {
  return execFileSync(
    'node',
    [path.join(root, 'scripts', 'knowledge-graph-merkle.js'), 'merge-resolve', oursPath, theirsPath],
    { cwd: root, encoding: 'utf8' }
  );
}

function readState(root) {
  return JSON.parse(fs.readFileSync(path.join(root, '.knowledge-graph-merkle.json'), 'utf8'));
}

test('unions observations unique to each side, keeping both', () => {
  const root = sandbox();
  const ours = writeFixture(root, 'ours.json', [obs('h1', 'Shared'), obs('h2', 'OursOnly')]);
  const theirs = writeFixture(root, 'theirs.json', [obs('h1', 'Shared'), obs('h3', 'TheirsOnly')]);

  runMergeResolve(root, ours, theirs);

  const state = readState(root);
  const names = state.observations.map((o) => o.entityName).sort();
  assert.deepStrictEqual(names, ['OursOnly', 'Shared', 'TheirsOnly']);
  assert.strictEqual(state.observations.length, 3, 'no duplication of the shared hash');

  fs.rmSync(root, { recursive: true, force: true });
});

test('is deterministic regardless of (ours, theirs) argument order, including same-timestamp ties', () => {
  const root = sandbox();
  // Both observations share a timestamp — this is exactly the case review
  // 2026-08-13 found the original timestamp-only sort was NOT stable across
  // argument order for.
  const a = writeFixture(root, 'a.json', [obs('hAAA', 'AlphaEntity', '2026-01-01T00:00:00.000Z')]);
  const b = writeFixture(root, 'b.json', [obs('hZZZ', 'ZuluEntity', '2026-01-01T00:00:00.000Z')]);

  runMergeResolve(root, a, b);
  const rootOrder = readState(root).observations.map((o) => o.hash);

  const root2 = sandbox();
  const a2 = writeFixture(root2, 'a.json', [obs('hAAA', 'AlphaEntity', '2026-01-01T00:00:00.000Z')]);
  const b2 = writeFixture(root2, 'b.json', [obs('hZZZ', 'ZuluEntity', '2026-01-01T00:00:00.000Z')]);
  runMergeResolve(root2, b2, a2); // swapped argument order

  const root2Order = readState(root2).observations.map((o) => o.hash);

  assert.deepStrictEqual(rootOrder, root2Order, 'observation order (and therefore the Merkle root) must not depend on which file is passed as ours vs theirs');
  assert.strictEqual(readState(root).merkleRoot, readState(root2).merkleRoot);

  fs.rmSync(root, { recursive: true, force: true });
  fs.rmSync(root2, { recursive: true, force: true });
});

test('rebuilds the Merkle root from the unioned observation set', () => {
  const root = sandbox();
  const ours = writeFixture(root, 'ours.json', [obs('h1', 'One')]);
  const theirs = writeFixture(root, 'theirs.json', [obs('h2', 'Two')]);

  runMergeResolve(root, ours, theirs);

  const state = readState(root);
  // buildMerkleTree of a 2-leaf tree is sha256(hash1 + hash2) in sorted order
  const crypto = require('node:crypto');
  const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
  const [h1, h2] = state.observations.map((o) => o.hash); // already sorted by the resolver
  assert.strictEqual(state.merkleRoot, sha256(h1 + h2));

  fs.rmSync(root, { recursive: true, force: true });
});

test('reconciles .knowledge-graph/graph.json from the merged state', () => {
  const root = sandbox();
  const ours = writeFixture(root, 'ours.json', [obs('h1', 'EntityA')]);
  const theirs = writeFixture(root, 'theirs.json', [obs('h2', 'EntityB')]);

  runMergeResolve(root, ours, theirs);

  const graph = JSON.parse(fs.readFileSync(path.join(root, '.knowledge-graph', 'graph.json'), 'utf8'));
  const names = graph.entities.map((e) => e.name).sort();
  assert.deepStrictEqual(names, ['EntityA', 'EntityB']);

  fs.rmSync(root, { recursive: true, force: true });
});

test('a malformed observation (no hash) is skipped, not silently collapsed into another entry', () => {
  const root = sandbox();
  const malformed = { entityName: 'Ghost', content: 'no hash field at all', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' };
  const ours = writeFixture(root, 'ours.json', [obs('h1', 'Real')]);
  const theirsPath = path.join(root, 'theirs.json');
  fs.writeFileSync(theirsPath, JSON.stringify({ merkleRoot: 'x', observations: [malformed], lastVerified: null, version: 1 }));

  const output = runMergeResolve(root, ours, theirsPath);

  const state = readState(root);
  assert.deepStrictEqual(state.observations.map((o) => o.entityName), ['Real'], 'the malformed observation must not appear in the merged state');
  assert.match(output, /malformed/i, 'must report that something was skipped, not stay silent');

  fs.rmSync(root, { recursive: true, force: true });
});

test('a missing/unparseable ours or theirs file produces a friendly error, not a raw stack trace', () => {
  const root = sandbox();
  const theirs = writeFixture(root, 'theirs.json', [obs('h1', 'Real')]);
  let threw = false;
  try {
    runMergeResolve(root, path.join(root, 'does-not-exist.json'), theirs);
  } catch (err) {
    threw = true;
    const combined = (err.stdout || '') + (err.stderr || '');
    assert.doesNotMatch(combined, /at Object\.readFileSync/, 'must not leak a raw Node stack trace to the operator');
  }
  assert.strictEqual(threw, true, 'a missing ours-file must exit non-zero');

  fs.rmSync(root, { recursive: true, force: true });
});
