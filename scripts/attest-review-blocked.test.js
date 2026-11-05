// attest-review-blocked.test — pins the "no re-review of a blocked commit" rule
// in scripts/attest-review.sh (canonical fleet gate, doxa-cns fleet/gates/,
// taken from Wamemba me's scripts/gate/rereview.mjs, its #408): a model review
// is a sample, so asking again about the SAME code proves nothing — a re-run
// on a blocked commit once PASSED by chance and the PR merged with its
// findings open. "blocked: <findings>" must record the block and attest
// NOTHING; that commit (and any commit with the same tree, e.g. an amend)
// can then never be attested; only changed code earns a new review. The
// test-gate waiver ("waived-tests:") stays allowed. A copy without the rule
// wrote "blocked: …" as a valid attestation, so this test fails on it.
//
// Drives the REAL script in a throwaway repo. Run: node --test scripts/attest-review-blocked.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SCRIPT = path.resolve(__dirname, 'attest-review.sh');

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

function tmpRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'attest-blocked-'));
  git(['init', '-q', '-b', 'main'], dir);
  git(['config', 'user.email', 'g@d'], dir);
  git(['config', 'user.name', 'g'], dir);
  fs.mkdirSync(path.join(dir, 'scripts'));
  // Only the script itself: no review-attest-note.mjs, so the portable-note
  // half (network: git push, gh) is skipped by design.
  fs.copyFileSync(SCRIPT, path.join(dir, 'scripts', 'attest-review.sh'));
  fs.writeFileSync(path.join(dir, 'code.txt'), 'v1\n');
  git(['add', '-A'], dir);
  git(['commit', '-qm', 'v1'], dir);
  return dir;
}

function attest(dir, verdict) {
  const r = spawnSync('bash', ['scripts/attest-review.sh', verdict], { cwd: dir, encoding: 'utf8' });
  return { code: r.status, out: r.stdout + r.stderr };
}

function ledgerRows(dir, name) {
  const p = path.join(dir, '.git', name);
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

test('a "blocked:" verdict attests nothing and is recorded in its own ledger', () => {
  const dir = tmpRepo();
  const r = attest(dir, 'blocked: 1 HIGH unbounded loop');
  assert.strictEqual(r.code, 0, r.out);
  assert.strictEqual(ledgerRows(dir, 'review-attest.jsonl').length, 0, 'a block must never become an attestation');
  const blocked = ledgerRows(dir, 'review-blocked.jsonl');
  assert.strictEqual(blocked.length, 1);
  assert.strictEqual(blocked[0].sha, git(['rev-parse', 'HEAD'], dir));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a blocked commit can never be attested afterwards — not even after an amend of the same tree', () => {
  const dir = tmpRepo();
  attest(dir, 'blocked: 1 HIGH unbounded loop');

  const again = attest(dir, 'clean');
  assert.strictEqual(again.code, 2, 'a second review of the same code is a re-roll, not a review');
  assert.strictEqual(ledgerRows(dir, 'review-attest.jsonl').length, 0);

  git(['commit', '-q', '--amend', '-m', 'v1 (reworded, same code)'], dir);
  const amended = attest(dir, 'findings-fixed: none');
  assert.strictEqual(amended.code, 2, 'same tree = same code: still blocked');
  assert.strictEqual(ledgerRows(dir, 'review-attest.jsonl').length, 0);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('changed code earns a new review, and the test waiver stays allowed on a blocked tip', () => {
  const dir = tmpRepo();
  attest(dir, 'blocked: 1 HIGH unbounded loop');

  const waiver = attest(dir, 'waived-tests: docs-only');
  assert.strictEqual(waiver.code, 0, 'waived-tests is the test gate\'s waiver, not a review outcome');

  fs.writeFileSync(path.join(dir, 'code.txt'), 'v2 — the fix\n');
  git(['commit', '-qam', 'v2'], dir);
  const fixed = attest(dir, 'clean');
  assert.strictEqual(fixed.code, 0, fixed.out);
  const rows = ledgerRows(dir, 'review-attest.jsonl');
  assert.strictEqual(rows.at(-1).sha, git(['rev-parse', 'HEAD'], dir));
  assert.strictEqual(rows.at(-1).verdict, 'clean');
  fs.rmSync(dir, { recursive: true, force: true });
});
