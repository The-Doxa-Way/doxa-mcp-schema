#!/usr/bin/env bash
#
# attest-review.sh — record that an independent review pass ran on HEAD.
#
# Part of the landing-gates suite (Garth 2026-07-16, ported from doxa-cns):
# .claude/hooks/review-gate.sh blocks doxa-openclaw PR merges with no
# attestation for a local branch tip, and .claude/hooks/test-gate.sh accepts
# "waived-tests:" entries from the same ledger. Run this AFTER the independent
# review pass (PR bot / /code-review by a non-author session) + fix round:
#
#   scripts/attest-review.sh "clean"                        # no findings left
#   scripts/attest-review.sh "findings-fixed: 2 LOW"        # fixed same round
#   scripts/attest-review.sh "waived: generated-state only" # review waiver
#   scripts/attest-review.sh "waived-tests: <reason>"       # test-gate waiver
#
# The ledger lives in the repo's .git dir (survives within a clone, never
# committed, never churns the tree). This is PROCESS enforcement — it makes
# forgetting the review pass impossible, it does not make the attestation
# adversarially trustworthy (the reviewer writes it). Waivers are the escape
# hatch and they are logged, so a bypass is always visible after the fact.

set -euo pipefail
verdict="${1:?usage: attest-review.sh \"<verdict>\" — e.g. \"clean\", \"findings-fixed: …\", \"waived: <reason>\", \"waived-tests: <reason>\"}"
# An option-looking argument is a mistake, not a verdict. `attest-review.sh
# --help` used to write a perfectly valid attestation with verdict "--help" —
# harmless noise until scripts/land-prs.mjs began treating an attestation as
# authority to merge unattended, at which point a fat-fingered flag became a
# merge authorization. (One such entry exists in this repo's ledger, from
# 2026-08-01.) Reject it loudly rather than banking it.
case "$verdict" in
  -*) echo "attest-review.sh: refusing to record \"$verdict\" as a verdict — it looks like a flag, not a review outcome." >&2; exit 2 ;;
esac
common="$(git rev-parse --path-format=absolute --git-common-dir)"
sha="$(git rev-parse HEAD)"
branch="$(git rev-parse --abbrev-ref HEAD)"
printf '{"sha":"%s","branch":"%s","verdict":%s,"at":"%s"}\n' \
  "$sha" "$branch" "$(printf '%s' "$verdict" | jq -R .)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "$common/review-attest.jsonl"
echo "attested: $branch@${sha:0:8} — $verdict"
