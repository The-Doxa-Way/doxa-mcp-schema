// WHY (gate-health NO_PR_HEAD_RESOLUTION, 2026-10-24): review-gate.sh matched
// the review attestation only against LOCAL worktree tips, so any attested
// local branch admitted ANY PR by number. The hook must judge the merged PR's
// real head SHA, and still fail open (old behaviour) when it cannot resolve it.
// Repo-agnostic: the same file runs in every repo that carries this hook.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: path.dirname(fileURLToPath(import.meta.url)), encoding: 'utf8' }).trim();
const HOOK = path.join(ROOT, '.claude/hooks/review-gate.sh');
const SLUG = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: ROOT, encoding: 'utf8' }).trim().replace(/^.*github\.com[:/]/, '').replace(/\.git$/, '');
const REPO = SLUG.split('/')[1];

function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rg-head-'));
  const git = (...a) => execFileSync('git', a, { cwd: dir, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('remote', 'add', 'origin', `https://github.com/${SLUG}.git`);
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'a');
  const a = git('rev-parse', 'HEAD');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'b');
  const b = git('rev-parse', 'HEAD');
  const common = git('rev-parse', '--path-format=absolute', '--git-common-dir');
  const bin = path.join(dir, 'fakebin');
  fs.mkdirSync(bin);
  return { dir, a, b, common, bin };
}

function fakeGh(bin, headSha) {
  const body = headSha === null ? 'exit 1' : `case "$*" in *"pr view"*) echo ${headSha} ;; *) exit 1 ;; esac`;
  fs.writeFileSync(path.join(bin, 'gh'), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

function run(sb, attested) {
  fs.writeFileSync(path.join(sb.common, 'review-attest.jsonl'), `{"sha":"${attested}","verdict":"clean"}\n`);
  const payload = JSON.stringify({
    tool_name: 'mcp__github__merge_pull_request',
    tool_input: { owner: SLUG.split('/')[0], repo: REPO, pullNumber: 7 },
    cwd: sb.dir,
  });
  return spawnSync('bash', [HOOK], {
    input: payload,
    cwd: sb.dir,
    env: { ...process.env, CLAUDE_PROJECT_DIR: sb.dir, PATH: `${sb.bin}:${process.env.PATH}` },
    encoding: 'utf8',
  }).status;
}

test('an attested LOCAL tip no longer admits a PR whose real head is unreviewed', () => {
  const sb = sandbox();
  fakeGh(sb.bin, sb.a); // PR #7 head = a (never attested); local HEAD = b (attested)
  assert.equal(run(sb, sb.b), 2);
});

test('the PR head itself attested: allowed', () => {
  const sb = sandbox();
  fakeGh(sb.bin, sb.a);
  assert.equal(run(sb, sb.a), 0);
});

test('PR head unresolvable (gh fails): falls back to local tips, as before', () => {
  const sb = sandbox();
  fakeGh(sb.bin, null);
  assert.equal(run(sb, sb.b), 0);
});
