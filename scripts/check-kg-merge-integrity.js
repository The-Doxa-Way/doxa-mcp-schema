#!/usr/bin/env node
/**
 * check-kg-merge-integrity.js — zero-LLM detector for the merkle-observation
 * data-loss class (Garth 2026-08-13: "this should be standing doctrine and
 * practice across all repos").
 *
 * Real incident: PR #343 (doxa-cns) fixed a real bug, but its KG entity was
 * silently lost when a merge conflict on .knowledge-graph-merkle.json was
 * resolved with `git checkout --theirs` — the branch's own observation was
 * discarded with no error anywhere, because the observations array is an
 * APPEND LOG and picking one side can only ever keep a subset. See
 * mergeResolve() in knowledge-graph-merkle.js for the correct fix
 * (hash-keyed union of both sides).
 *
 * Scope: only .knowledge-graph-merkle.json is compared. .knowledge-graph/
 * graph.json is a pure projection of it (rebuilt by reconcile()/mergeResolve()
 * from the merkle observations, never hand-merged) — the merkle log is the
 * one place data loss is unrecoverable, so it's the one place this detector
 * needs to look. (`relations` in graph.json is a separate, pre-existing gap
 * with no merkle backing at all — out of scope here, tracked separately.)
 *
 * A naive count comparison (merged >= max(parent counts)) is NOT enough to
 * catch this: in the real incident, the branch's tip and origin/main's tip
 * both happened to hold 970 observations (the branch had gained its own
 * fix's entity; main had independently gained a different PR's entity in
 * the meantime) — so `git checkout --theirs` produced a merge result whose
 * COUNT never dropped below either parent, while still silently discarding
 * the branch's specific entity. This script instead compares observation
 * HASH SETS: a correct union's hash set must equal parent1's hashes UNION
 * parent2's hashes, exactly. Any hash present in a parent but absent from
 * the merge result is a confirmed, named data-loss violation — no count
 * coincidence can hide it.
 *
 * Usage: node scripts/check-kg-merge-integrity.js <base-ref> [<head-ref>]
 *   head-ref defaults to HEAD.
 * Exit 0: no violation (including "no merge commits in range" / "file never
 *   touched" — this check only fires on a CONFIRMED drop, matching the
 *   fail-open philosophy of every other gate in this fleet). ALSO exit 0 on
 *   any unexpected internal error (a crash must never read as a violation —
 *   see the top-level try/catch in main()'s caller below; review 2026-08-13
 *   caught this reported as a real gap: an uncaught throw here previously
 *   exited 1, indistinguishable from a confirmed drop, and the calling hook
 *   blocks on exit 1 — a bug in THIS script would then wrongly block a
 *   legitimate landing instead of failing open like every other check here).
 * Exit 1: a violation was found; details printed to stderr.
 */

const { execSync } = require('child_process');

// maxBuffer: execSync's 1MB default silently throws ENOBUFS on a repo this
// size (doxa-cns's merkle log is >1MB) — caught by the callers' try/catch
// and treated as "unreadable, fail open," which would make this whole
// detector a no-op on the exact repo it matters most for. 64MB should
// outlive this fleet's KG logs for a long time; if it doesn't, the failure
// mode is still fail-open, never a false block.
function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 }).trim();
}

/** Returns { hash -> entityName } for a ref, or null if unreadable/unparseable. */
function observationsAt(ref, path) {
  let content;
  try {
    content = sh(`git show ${ref}:${path}`);
  } catch {
    return null; // file didn't exist at this ref — not this check's concern
  }
  let data;
  try {
    data = JSON.parse(content);
  } catch {
    return null; // unparseable — not this check's concern (fail open)
  }
  if (!Array.isArray(data.observations)) return null;
  const map = new Map();
  for (const obs of data.observations) {
    // A malformed observation (missing/non-string hash) is skipped, not
    // indexed under a shared falsy/undefined key — review 2026-08-13: the
    // prior version's `if (obs && obs.hash)` let a non-string hash (e.g. a
    // hand-edited file with a numeric or duplicate-empty hash) collapse
    // multiple observations onto one Map key, silently discarding the
    // others INSIDE the very tool meant to catch silent discarding.
    if (obs && typeof obs.hash === 'string' && obs.hash.length > 0) {
      map.set(obs.hash, typeof obs.entityName === 'string' ? obs.entityName : '(unknown entity)');
    }
  }
  return map;
}

function run(base, head) {
  const KG_PATH = '.knowledge-graph-merkle.json';
  let mergeCommits;
  try {
    mergeCommits = sh(`git rev-list --merges ${base}..${head}`).split('\n').filter(Boolean);
  } catch {
    return { violations: [] }; // no such range (e.g. base doesn't exist locally) — fail open
  }

  const violations = [];

  for (const mergeSha of mergeCommits) {
    // No "did this commit touch KG_PATH" pre-filter: `git show`'s default
    // diff format for a 2-parent merge commit shows NOTHING (git picks no
    // diff strategy for merges unless -m/-c/--cc is passed), so a
    // --name-only pre-check here silently skipped every real merge commit
    // and made this whole detector a no-op — caught while building it, by
    // testing directly against the incident it exists to catch. Reading the
    // observation sets at merge+both parents unconditionally is cheap
    // enough not to need the filter.

    let parents;
    try {
      parents = sh(`git log -1 --format=%P ${mergeSha}`).split(' ').filter(Boolean);
    } catch {
      continue;
    }
    if (parents.length < 2) continue; // not actually a 2-parent merge

    const mergeObs = observationsAt(mergeSha, KG_PATH);
    if (mergeObs === null) continue; // couldn't read/parse — fail open

    const parentObsMaps = parents
      .map((p) => observationsAt(p, KG_PATH))
      .filter((m) => m !== null);
    if (parentObsMaps.length === 0) continue;

    const dropped = [];
    for (const parentObs of parentObsMaps) {
      for (const [hash, entityName] of parentObs) {
        if (!mergeObs.has(hash)) dropped.push({ hash, entityName });
      }
    }
    if (dropped.length > 0) {
      violations.push({ mergeSha, dropped });
    }
  }

  return { violations };
}

function main() {
  const base = process.argv[2];
  const head = process.argv[3] || 'HEAD';
  if (!base) {
    console.error('Usage: check-kg-merge-integrity.js <base-ref> [<head-ref>]');
    process.exit(0); // fail open on misuse — never block on a bad invocation
  }

  const { violations } = run(base, head);

  if (violations.length === 0) {
    process.exit(0);
  }

  console.error('⛔ kg-merge-integrity — a merge commit dropped knowledge-graph observations:\n');
  for (const v of violations) {
    console.error(`  ${v.mergeSha.slice(0, 8)} dropped ${v.dropped.length} observation(s) present in a parent but missing from the merge result:`);
    for (const d of v.dropped.slice(0, 10)) {
      console.error(`    - [${d.entityName}] (hash ${d.hash.slice(0, 12)}...)`);
    }
    if (v.dropped.length > 10) console.error(`    ...and ${v.dropped.length - 10} more`);
  }
  console.error('\nA conflict on this file was resolved by picking one side instead of unioning');
  console.error('both — the observations array is an append log, so this ALWAYS loses data.');
  console.error('Fix: re-resolve with the merge-resolve command, which unions both sides by hash:');
  console.error('  git show :2:.knowledge-graph-merkle.json > /tmp/ours.json');
  console.error('  git show :3:.knowledge-graph-merkle.json > /tmp/theirs.json');
  console.error('  node scripts/knowledge-graph-merkle.js merge-resolve /tmp/ours.json /tmp/theirs.json');
  process.exit(1);
}

// Top-level guard: ANY uncaught exception here must fail OPEN (exit 0), never
// exit non-zero — the calling hook cannot tell "this script found a real
// violation" apart from "this script crashed" by exit code alone (both were
// exit 1 before this fix), and a crash must never block a legitimate landing.
try {
  main();
} catch (err) {
  console.error(`check-kg-merge-integrity.js: internal error, failing open: ${err && err.message}`);
  process.exit(0);
}
