// kg-save-gate-merge-integrity.test.js — proves the merge-integrity check
// actually fires when routed through the REAL kg-save-gate.sh hook for a
// `gh pr merge` landing, not just when the detector script is invoked
// directly (scripts/check-kg-merge-integrity.test.js already covers the
// detector in isolation; this covers the wiring).
//
// Review 2026-08-13 (propagated from doxa-cns's own placement fix) found the
// check originally landed AFTER the repo_common and base/empty-range checks
// in this file — an early exit 0 from either of those could skip past a
// check placed later without ever reaching it. It now runs immediately after
// cwd/worktree validation, before every other early-exit path. The first
// test below asserts that placement directly in the hook's source (the
// shape a regression would break); the rest drive the REAL hook against a
// throwaway repo containing a synthetic instance of the real incident (a
// merge commit that drops an observation unique to one parent) to prove the
// check actually blocks a `gh pr merge` command, not just on paper.
//
// Run: node --test scripts/kg-save-gate-merge-integrity.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const HOOK = path.resolve(__dirname, '../.claude/hooks/kg-save-gate.sh');
const REAL_INTEGRITY_SCRIPT = path.resolve(__dirname, 'check-kg-merge-integrity.js');

test('the merge-integrity check is wired BEFORE the repo_common bail, not after', () => {
  const src = fs.readFileSync(HOOK, 'utf8');
  const integrityIdx = src.indexOf('check-kg-merge-integrity.js');
  const repoCommonIdx = src.indexOf('repo_common="$(git rev-parse');
  assert.ok(integrityIdx > -1, 'the hook must still reference check-kg-merge-integrity.js');
  assert.ok(repoCommonIdx > -1, 'the hook must still have the repo_common bail');
  assert.ok(
    integrityIdx < repoCommonIdx,
    'the merge-integrity check must run before the repo_common early-exit, or a landing for a repo that fails that check would skip it entirely'
  );
});

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

function merkle(observations) {
  return JSON.stringify({ merkleRoot: 'x', observations, lastVerified: null, version: 1 }, null, 2);
}

function writeAndCommit(dir, observations, message) {
  fs.writeFileSync(path.join(dir, '.knowledge-graph-merkle.json'), merkle(observations));
  git(['add', '-A'], dir);
  git(['commit', '-qm', message], dir);
  return git(['rev-parse', 'HEAD'], dir);
}

// Builds a throwaway repo shaped like the real incident:
//   A (root, obs h1)
//   ├─ main tip M1 (adds h2)   <- origin/main points here (already "pushed")
//   └─ feature tip F1 (adds h3)
// HEAD = a merge of M1 and F1 resolved by keeping ONLY M1's content (the
// `git checkout --theirs`/`--ours` anti-pattern) — h3 (unique to F1, a real
// parent of the merge) is silently dropped from the result.
function repoWithDroppedObservation() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kgsg-'));
  git(['init', '-q', '-b', 'main'], dir);
  git(['config', 'user.email', 'g@d'], dir);
  git(['config', 'user.name', 'g'], dir);

  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  fs.copyFileSync(REAL_INTEGRITY_SCRIPT, path.join(dir, 'scripts', 'check-kg-merge-integrity.js'));

  const base = writeAndCommit(dir, [{ hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' }], 'base');

  const m1 = writeAndCommit(dir, [
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h2', entityName: 'Two', content: 'c', provenance: {}, timestamp: '2026-01-02T00:00:00.000Z' },
  ], 'M1: add Two');
  // origin/main = M1, simulating "already pushed" state the merge lands onto.
  git(['update-ref', 'refs/remotes/origin/main', m1], dir);

  git(['checkout', '-q', '-b', 'feature', base], dir);
  writeAndCommit(dir, [
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h3', entityName: 'Three', content: 'c', provenance: {}, timestamp: '2026-01-03T00:00:00.000Z' },
  ], 'F1: add Three');

  git(['checkout', '-q', 'main'], dir);
  try { git(['merge', '--no-commit', '--no-ff', 'feature'], dir); } catch { /* expected: conflicts on the merkle file */ }
  // Anti-pattern resolution: keep ONLY main's side, silently dropping h3.
  fs.writeFileSync(path.join(dir, '.knowledge-graph-merkle.json'), merkle([
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h2', entityName: 'Two', content: 'c', provenance: {}, timestamp: '2026-01-02T00:00:00.000Z' },
  ]));
  git(['add', '-A'], dir);
  git(['commit', '-qm', 'Merge feature into main (drops h3 — simulated incident)'], dir);

  return dir;
}

// Same shape, but resolved CORRECTLY (union of both sides) — nothing dropped.
function repoWithCorrectMerge() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kgsg-'));
  git(['init', '-q', '-b', 'main'], dir);
  git(['config', 'user.email', 'g@d'], dir);
  git(['config', 'user.name', 'g'], dir);

  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  fs.copyFileSync(REAL_INTEGRITY_SCRIPT, path.join(dir, 'scripts', 'check-kg-merge-integrity.js'));

  const base = writeAndCommit(dir, [{ hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' }], 'base');

  const m1 = writeAndCommit(dir, [
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h2', entityName: 'Two', content: 'c', provenance: {}, timestamp: '2026-01-02T00:00:00.000Z' },
  ], 'M1: add Two');
  git(['update-ref', 'refs/remotes/origin/main', m1], dir);

  git(['checkout', '-q', '-b', 'feature', base], dir);
  writeAndCommit(dir, [
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h3', entityName: 'Three', content: 'c', provenance: {}, timestamp: '2026-01-03T00:00:00.000Z' },
  ], 'F1: add Three');

  git(['checkout', '-q', 'main'], dir);
  try { git(['merge', '--no-commit', '--no-ff', 'feature'], dir); } catch { /* expected: conflicts on the merkle file */ }
  // Correct resolution: union of both sides — nothing dropped.
  fs.writeFileSync(path.join(dir, '.knowledge-graph-merkle.json'), merkle([
    { hash: 'h1', entityName: 'Base', content: 'c', provenance: {}, timestamp: '2026-01-01T00:00:00.000Z' },
    { hash: 'h2', entityName: 'Two', content: 'c', provenance: {}, timestamp: '2026-01-02T00:00:00.000Z' },
    { hash: 'h3', entityName: 'Three', content: 'c', provenance: {}, timestamp: '2026-01-03T00:00:00.000Z' },
  ]));
  git(['add', '-A'], dir);
  git(['commit', '-qm', 'Merge feature into main (correct union)'], dir);

  return dir;
}

// CLAUDE_PROJECT_DIR=dir makes the hook's repo_common check pass (the
// resolved landing dir IS the "project" the hook believes it's gating) so
// the run reaches the hand-authored/kg-change tail of the hook rather than
// bailing early on an unrelated-repo check — the merge-integrity check must
// still fire (and block) regardless of what happens further down.
function runGate(dir, cmd) {
  try {
    execFileSync('bash', [HOOK], {
      cwd: dir,
      env: { ...process.env, CLAUDE_PROJECT_DIR: dir },
      input: JSON.stringify({ tool_input: { command: cmd }, cwd: dir }),
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    return { status: 0 };
  } catch (e) {
    return { status: e.status, stderr: (e.stderr || '').toString() };
  }
}

test('gh pr merge blocks a merge commit that dropped an observation', () => {
  const dir = repoWithDroppedObservation();
  const result = runGate(dir, 'gh pr merge 4 --repo The-Doxa-Way/doxa-mcp-schema --squash');
  assert.strictEqual(result.status, 2, 'must block on a confirmed dropped observation');
  assert.match(result.stderr, /dropped knowledge-graph observations/);
  assert.match(result.stderr, /Three/, 'must name the dropped entity');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('gh pr merge passes a correctly-unioned merge (no false positive)', () => {
  const dir = repoWithCorrectMerge();
  const result = runGate(dir, 'gh pr merge 4 --repo The-Doxa-Way/doxa-mcp-schema --squash');
  assert.strictEqual(result.status, 0, 'a correct union must not be blocked');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('git push also runs the merge-integrity check (not just gh pr merge)', () => {
  const dir = repoWithDroppedObservation();
  const result = runGate(dir, 'git push origin main');
  assert.strictEqual(result.status, 2, 'a git push landing the same dropped-observation range must also block');
  assert.match(result.stderr, /dropped knowledge-graph observations/);

  fs.rmSync(dir, { recursive: true, force: true });
});
