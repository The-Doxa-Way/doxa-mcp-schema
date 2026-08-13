// check-kg-merge-integrity.test.js — drives the REAL script against a
// throwaway git repo, reproducing the exact incident it exists to catch
// (PR #343: `git checkout --theirs` on a merge conflict silently dropped a
// branch's own KG observation) and confirming a correct (unioned) merge
// passes clean.
//
// Run: node --test scripts/check-kg-merge-integrity.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SCRIPT = path.resolve(__dirname, 'check-kg-merge-integrity.js');
const KG_FILE = '.knowledge-graph-merkle.json';

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

function state(observations) {
  return JSON.stringify({ merkleRoot: 'x', observations, lastVerified: null, version: 1 }, null, 2);
}

function obs(hash, entityName) {
  return { hash, entityName, content: entityName, provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' };
}

function repo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kgmi-'));
  git(['init', '-q', '-b', 'main'], dir);
  git(['config', 'user.email', 'g@d'], dir);
  git(['config', 'user.name', 'g'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity')]));
  git(['add', '-A'], dir);
  git(['commit', '-qm', 'base'], dir);
  return dir;
}

function runCheck(dir, base, head) {
  try {
    execFileSync('node', [SCRIPT, base, head || 'HEAD'], { cwd: dir, encoding: 'utf8' });
    return { status: 0, output: '' };
  } catch (err) {
    return { status: err.status, output: (err.stdout || '') + (err.stderr || '') };
  }
}

test('catches the real incident shape: checkout --theirs on a KG conflict silently drops the branch\'s own observation', () => {
  const dir = repo();
  const base = git(['rev-parse', 'HEAD'], dir);

  // Branch adds its own observation.
  git(['checkout', '-qb', 'feature'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('branch1', 'BranchOnlyEntity')]));
  git(['commit', '-qam', 'feature: add BranchOnlyEntity'], dir);

  // main independently gains a DIFFERENT observation (same final count as
  // the branch — this is the exact coincidence that made the real incident
  // invisible to a naive count-only check).
  git(['checkout', '-q', 'main'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('main1', 'MainOnlyEntity')]));
  git(['commit', '-qam', 'main: add MainOnlyEntity'], dir);

  // Merge feature into main, and resolve the conflict the WRONG way: take
  // main's version wholesale, discarding the branch's BranchOnlyEntity.
  try {
    git(['merge', '--no-ff', '-q', '-m', 'merge feature (bad resolution)', 'feature'], dir);
  } catch {
    // expected: real conflict
  }
  // The wrong resolution: keep main's content as-is, discarding the
  // branch's BranchOnlyEntity entirely — this is what `git checkout --ours`
  // (main's own side, since we're merging feature INTO main) does in the
  // real incident's shape.
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('main1', 'MainOnlyEntity')]));
  git(['add', KG_FILE], dir);
  git(['commit', '--no-edit', '-q'], dir);
  const mergeSha = git(['rev-parse', 'HEAD'], dir);

  const result = runCheck(dir, base, mergeSha);
  assert.strictEqual(result.status, 1, 'must exit 1 — a real observation was dropped');
  assert.match(result.output, /BranchOnlyEntity/, 'must name the specific dropped entity');
  assert.match(result.output, /merge-resolve/, 'must point at the fix');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('a correctly unioned merge (both observations kept) passes clean', () => {
  const dir = repo();
  const base = git(['rev-parse', 'HEAD'], dir);

  git(['checkout', '-qb', 'feature'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('branch1', 'BranchOnlyEntity')]));
  git(['commit', '-qam', 'feature: add BranchOnlyEntity'], dir);

  git(['checkout', '-q', 'main'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('main1', 'MainOnlyEntity')]));
  git(['commit', '-qam', 'main: add MainOnlyEntity'], dir);

  try {
    git(['merge', '--no-ff', '-q', '-m', 'merge feature (correct union)', 'feature'], dir);
  } catch {
    // expected: real conflict
  }
  // Correct resolution: union of all three observations (base + both sides).
  fs.writeFileSync(path.join(dir, KG_FILE), state([
    obs('base1', 'BaseEntity'), obs('main1', 'MainOnlyEntity'), obs('branch1', 'BranchOnlyEntity'),
  ]));
  git(['add', KG_FILE], dir);
  git(['commit', '--no-edit', '-q'], dir);
  const mergeSha = git(['rev-parse', 'HEAD'], dir);

  const result = runCheck(dir, base, mergeSha);
  assert.strictEqual(result.status, 0, 'a correct union must pass with no violation');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('a range with no merge commits at all passes clean (fast-forward-only history)', () => {
  const dir = repo();
  const base = git(['rev-parse', 'HEAD'], dir);
  fs.writeFileSync(path.join(dir, KG_FILE), state([obs('base1', 'BaseEntity'), obs('linear1', 'LinearEntity')]));
  git(['commit', '-qam', 'linear commit, no merge'], dir);

  const result = runCheck(dir, base, 'HEAD');
  assert.strictEqual(result.status, 0, 'no merge commits in range -> nothing for this check to evaluate');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('misuse (no base ref given) fails open rather than crashing', () => {
  const dir = repo();
  try {
    execFileSync('node', [SCRIPT], { cwd: dir, encoding: 'utf8' });
  } catch (err) {
    assert.fail(`must not throw/exit non-zero on missing args, got status ${err.status}`);
  }
  fs.rmSync(dir, { recursive: true, force: true });
});
