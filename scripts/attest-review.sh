#!/usr/bin/env bash
#
# attest-review.sh — record that an independent review pass ran on HEAD.
#
# Part of the review-gate pair (.claude/hooks/review-gate.sh blocks doxa-mcp-schema
# PR merges with no attestation for the branch tip; .claude/hooks/test-gate.sh
# accepts "waived-tests: …" entries from the same ledger). Run this AFTER the
# /code-review (or ontology-reviewer) pass + fix round completes:
#
#   scripts/attest-review.sh "clean"                        # no findings left
#   scripts/attest-review.sh "findings-fixed: 2 LOW"        # fixed same round
#   scripts/attest-review.sh "waived: generated-state only" # explicit bypass
#   scripts/attest-review.sh "waived-tests: <reason>"       # test-gate waiver
#   scripts/attest-review.sh "blocked: 1 HIGH <what>"       # the review BLOCKED HEAD:
#                         attests nothing; HEAD can then never be attested (see below)
#
# An optional SECOND argument is a free-text findings summary carried in the
# portable note (review finding L5 — the field used to be set to a copy of
# the verdict, so it carried no information):
#
#   scripts/attest-review.sh "findings-fixed: 2 LOW" "unpinned action sha; no job timeout"
#
# Optional env ATTEST_REVIEWER_MODEL (e.g. claude-opus-5-5, the pinned review
# tier) adds a "reviewer_model" field to the jsonl row; unset, the row is as before.
#
# Optional env ATTEST_REVIEW_LEVEL (low|medium|high|xhigh|max — the /code-review
# effort level that ran) adds a "review_level" field to the jsonl row and to the
# portable note. Garth 2026-11-11: every push needs ONE `/code-review max` pass,
# and .claude/hooks/push-review-gate.sh accepts only review_level "max" (or an
# explicit `waived:`). Unset, the row is as before; any other value is refused.
#
#   ATTEST_REVIEW_LEVEL=max scripts/attest-review.sh "clean"
#
# The ledger lives in the repo's .git dir (survives within a clone, never
# committed, never churns the tree). This is PROCESS enforcement — it makes
# forgetting the review pass impossible, it does not make the attestation
# adversarially trustworthy (the reviewer writes it). Waivers are the escape
# hatch and they are logged, so a bypass is always visible after the fact.
#
# PORTABLE evidence (CEO ruling, 2026-09-11): the jsonl line above is
# SHA-keyed and never leaves this laptop, so CI could not see it and a
# rebase/base-merge/amend silently invalidated it (new SHA, same content) —
# forcing a redundant model review of identical content. In addition to the
# jsonl line (the sha/branch/verdict/at fields are kept exactly as-is, plus
# an optional "parsed" label field added by slice 05 step 0 - every existing
# consumer, waiver, and ledger reader keeps working unchanged), this also
# computes a CONTENT key
# (a normalised hash of the diff against the merge-base — stable across a
# rebase and across merging the base in, and NOT blind to whitespace, see
# scripts/lib/review-attest.js) and writes + pushes it as a git note on
# refs/notes/review-attest, so
# .claude/hooks/review-gate.sh and .github/workflows/gate.yml's gate/review
# job can both recognize a rebase/merge of ALREADY-reviewed content and skip
# a redundant pass. This half is best-effort: no origin remote, no node, no
# scripts/review-attest-note.mjs in this repo, or a push failure only skips it
# or produces a warning — the jsonl attestation above is unconditional and
# this script's exit code never depends on it. Run it BEFORE `gh pr create`,
# or the PR's first CI run will not see the note.
#
# The note is keyed against the PR's BASE branch (review finding L3): with no
# --base-name the library always assumed `main`, so a PR against any other
# base could never reuse its own attestation. The base is taken from
# $ATTEST_BASE_REF when set, else from `gh pr view` when gh is available and
# this branch has a PR, else this repo's integration branch (main).

set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "error: jq required for attestation" >&2; exit 1; }
verdict="${1:?usage: attest-review.sh \"<verdict>\" [\"<findings summary>\"] — verdict e.g. \"clean\", \"findings-fixed: …\", \"waived: <reason>\", \"waived-tests: <reason>\"}"
# An option-looking argument is a mistake, not a verdict (openclaw fix,
# 2026-08-01). `attest-review.sh --help` used to write a perfectly valid
# attestation with verdict "--help" — harmless noise until land-prs.mjs began
# treating an attestation as authority to merge unattended, at which point a
# fat-fingered flag became a merge authorization. Reject it loudly.
case "$verdict" in
  -*) echo "attest-review.sh: refusing to record \"$verdict\" as a verdict — it looks like a flag, not a review outcome." >&2; exit 2 ;;
esac
findings="${2:-}"
review_level="$(printf '%s' "${ATTEST_REVIEW_LEVEL:-}" | tr '[:upper:]' '[:lower:]')"
case "$review_level" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "attest-review.sh: refusing ATTEST_REVIEW_LEVEL=\"${ATTEST_REVIEW_LEVEL}\" — use one of low|medium|high|xhigh|max (the /code-review effort level that ran)." >&2; exit 2 ;;
esac
common="$(git rev-parse --path-format=absolute --git-common-dir)"
[ -n "$common" ] || { echo "error: not inside a git repository — cannot record attestation" >&2; exit 1; }
sha="$(git rev-parse HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No re-review of a blocked commit (taken from Wamemba me, scripts/gate/rereview.mjs,
# its #408: a review re-run on a BLOCKED commit PASSED by chance and the PR merged
# with its findings open). A model review is a sample; asking again about the same
# code proves nothing. "blocked: <findings>" records that a review blocked HEAD, in
# its own ledger (never review-attest.jsonl, so no ledger reader can take it for an
# attestation), and attests nothing. After that, HEAD — and any commit with the
# same tree (an amend or a re-commit of the same code) — can never be attested
# or waived: only changed code earns a new review. review-gate.sh drops a blocked
# tip from its candidates too. "waived-tests:" stays allowed — it is the test
# gate's waiver, not a review outcome. Case-insensitive ("BLOCKED:" is a block).
blocked_ledger="$common/review-blocked.jsonl"
tree="$(git rev-parse 'HEAD^{tree}')"
verdict_lc="$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')"
case "$verdict_lc" in
  blocked:*)
    jq -n -c --arg sha "$sha" --arg tree "$tree" --arg branch "$branch" --arg verdict "$verdict" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{sha:$sha, tree:$tree, branch:$branch, verdict:$verdict, at:$at}' >> "$blocked_ledger"
    echo "blocked: $branch@${sha:0:8} — no attestation recorded; fix it in a new commit, then review that commit"
    exit 0 ;;
  waived-tests:*) ;;
  *)
    if [ -f "$blocked_ledger" ] && grep -qF -e "\"sha\":\"$sha\"" -e "\"tree\":\"$tree\"" "$blocked_ledger"; then
      echo "attest-review.sh: refusing — a review BLOCKED ${sha:0:8} and it is unchanged. A second review of the same code is a re-roll, not a review: fix it in a new commit and review that." >&2
      exit 2
    fi ;;
esac

# Structured verdict label (jev-specialist-roles slice 05 step 0): a
# best-effort parse of $verdict into findings/rounds/tests, added to the
# jsonl line as "parsed" when it succeeds. This is a label column for a
# later Jev role, not part of the attestation's authority - no node, a
# missing library (most repos carry no scripts/lib/attest-verdict.js), or a
# parse failure must never fail the attestation, so it just omits the field
# (fail-open, same rule as the note push below).
parsed_json=""
if command -v node >/dev/null 2>&1 && [ -f "$script_dir/lib/attest-verdict.js" ]; then
  parsed_json="$(node -e '
    const { parseVerdict } = require(process.argv[1]);
    const result = parseVerdict(process.argv[2]);
    delete result.raw;
    process.stdout.write(JSON.stringify(result));
  ' "$script_dir/lib/attest-verdict.js" "$verdict" 2>/dev/null)" || parsed_json=""
  printf '%s' "$parsed_json" | jq -e . >/dev/null 2>&1 || parsed_json=""
fi

at_jsonl="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$parsed_json" ]; then
  row="$(jq -n -c --arg sha "$sha" --arg branch "$branch" --arg verdict "$verdict" \
    --arg at "$at_jsonl" --argjson parsed "$parsed_json" \
    '{sha:$sha, branch:$branch, verdict:$verdict, at:$at, parsed:$parsed}')"
else
  row="$(printf '{"sha":"%s","branch":"%s","verdict":%s,"at":"%s"}' \
    "$sha" "$branch" "$(printf '%s' "$verdict" | jq -R .)" "$at_jsonl")"
fi
# Optional, self-reported like the verdict (Garth 2026-09-26): the gates pin
# the review pass to claude-opus-5-5; this records which model actually ran it.
if [ -n "${ATTEST_REVIEWER_MODEL:-}" ]; then
  row="$(printf '%s' "$row" | jq -c --arg m "$ATTEST_REVIEWER_MODEL" '. + {reviewer_model:$m}')"
fi
if [ -n "$review_level" ]; then
  row="$(printf '%s' "$row" | jq -c --arg l "$review_level" '. + {review_level:$l}')"
fi
printf '%s\n' "$row" >> "$common/review-attest.jsonl"
echo "attested: $branch@${sha:0:8} — $verdict${review_level:+ (review level: $review_level)}"

if command -v node >/dev/null 2>&1 && [ -f "$script_dir/review-attest-note.mjs" ]; then
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reviewer="$(git config user.email 2>/dev/null || true)"
  base_ref="${ATTEST_BASE_REF:-}"
  if [ -z "$base_ref" ] && command -v gh >/dev/null 2>&1; then
    base_ref="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)"
  fi
  [ -n "$base_ref" ] || base_ref='main'   # doxa-app fix: its base is not main
  note_args=(--head "$sha" --branch "$branch" --verdict "$verdict"
             --reviewer "${reviewer:-unknown}" --at "$at" --base-name "$base_ref")
  if [ -n "$findings" ]; then note_args+=(--findings-summary "$findings"); fi
  if [ -n "$review_level" ]; then note_args+=(--review-level "$review_level"); fi
  note_result="$(node "$script_dir/review-attest-note.mjs" "${note_args[@]}" 2>/dev/null)" || note_result=""
  if [ -n "$note_result" ] && printf '%s' "$note_result" | jq -e '.written and .pushed' >/dev/null 2>&1; then
    echo "portable: content key recorded + pushed (refs/notes/review-attest)"
  elif [ -n "$note_result" ] && printf '%s' "$note_result" | jq -e '.written' >/dev/null 2>&1; then
    echo "warning: portable note written locally but NOT pushed — $(printf '%s' "$note_result" | jq -r '.reason // "unknown reason"')" >&2
  else
    echo "warning: portable note not recorded — $(printf '%s' "$note_result" | jq -r '.reason // "unknown reason"' 2>/dev/null || echo 'review-attest-note.mjs failed')" >&2
  fi
fi
