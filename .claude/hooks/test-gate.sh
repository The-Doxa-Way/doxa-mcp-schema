#!/usr/bin/env bash
#
# test-gate.sh — PreToolUse gate: code changes need test changes.
# Garth's standing rule (2026-07-16): "tests for all the code we write."
# Ported into doxa-mcp-schema 2026-08-11 (landing-gates bootstrap).
#
# A doxa-mcp-schema PR merge — via mcp__github__merge_pull_request OR a Bash
# `gh pr merge` — is blocked when the chunk (merge-base(origin/main, tip)..tip,
# across HEAD and all worktree tips) adds or modifies hand-authored code while
# changing NO test file. The escape hatch is an EXPLICIT logged waiver in the
# shared attestation ledger: scripts/attest-review.sh "waived-tests: <reason>".
#
# What counts as CODE (this repo's actual source surfaces — survey-verified
# 2026-08-11): server/src/**/*.ts, server/scripts/*.mjs,
# clients/typescript/src/**/*.ts, and top-level scripts/**/*.{js,mjs,sh} (the
# doxa-cns CLAUDE.md standing pattern for test-gate.sh explicitly names
# `scripts/` as a gated code path — this repo's own landing-gate infra under
# scripts/ is not exempt from its own rule). Deliberately NOT code: JSON
# schemas (schemas/**), example fixtures (examples/**), docs (README/
# CONTRIBUTING/PUBLISHING.md), server.json, glama.json — this repo is mostly
# schemas/examples/docs, and a doc-or-schema-only PR must not misfire the gate.
#
# What counts as a TEST change:
#   server/src/**/*.test.ts   clients/typescript/src/**/*.test.ts
#   server/test/**            clients/typescript/test/**
#   scripts/**/*.test.{js,mjs}
# (clients/typescript/src/index.test.ts is the established convention already
# in this repo.)
#
# FAIL-OPEN: any uncertainty allows. Only the confirmed case blocks: code
# changed, zero test changes, zero waiver for the tip.
#
# Exit codes: 0 = allow, 2 = block (stderr shown to the model).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

repo="$(printf '%s' "$payload" | jq -r '.tool_input.repo // empty' 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"

dir="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ -n "$repo" ]; then
  # MCP merge tool: gate only this repo.
  [ "$repo" = "doxa-mcp-schema" ] || exit 0
elif [ -n "$cmd" ]; then
  # Bash tool: gate only `gh pr merge` at command position (same matching as
  # review-gate.sh — under-block, never over-block).
  printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cd[[:space:]]+[^;&|]+(&&|;)[[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|>]|$)' || exit 0

  flag_repo="$(printf '%s' "$cmd" | grep -oE '(-R|--repo)([[:space:]]+|=)[^[:space:];&|]+' | head -1 | sed -E 's/^(-R|--repo)([[:space:]]+|=)//')"
  if [ -n "$flag_repo" ]; then
    case "$flag_repo" in
      doxa-mcp-schema|*/doxa-mcp-schema) ;;
      *) exit 0 ;;
    esac
  else
    hook_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    cmd_cd="$(printf '%s' "$cmd" | grep -oE '^[[:space:]]*cd[[:space:]]+/[^[:space:];&|]+' | head -1 | sed -E 's#^[[:space:]]*cd[[:space:]]+##')"
    if [ -n "$cmd_cd" ] && [ -d "$cmd_cd" ]; then
      dir="$cmd_cd"
    else
      dir="${hook_cwd:-$dir}"
    fi
    repo_common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
    proj_common="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [ -n "$proj_common" ] || exit 0
    [ "$repo_common" = "$proj_common" ] || exit 0
  fi
else
  exit 0
fi

cd "$dir" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
ledger="$common/review-attest.jsonl"

code_re='^(server/src/.+\.ts|server/scripts/.+\.mjs|clients/typescript/src/.+\.ts|scripts/.+\.(js|mjs|sh))$'
test_re='^(server/src/.+\.test\.ts|server/test/.+|clients/typescript/src/.+\.test\.ts|clients/typescript/test/.+|scripts/.+\.test\.(js|mjs))$'

# Evaluate HEAD plus every worktree tip; the merge could land any of them.
tips="$(git rev-parse HEAD 2>/dev/null)
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^HEAD //p')"

code_without_tests=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  base="$(git merge-base "$sha" origin/main 2>/dev/null)" || continue
  [ "$base" = "$sha" ] && continue   # nothing landing from this tip
  changed="$(git diff --name-only "$base" "$sha" 2>/dev/null)" || continue
  tests="$(printf '%s\n' "$changed" | grep -E "$test_re")"
  code="$(printf '%s\n' "$changed" | grep -vE "$test_re" | grep -E "$code_re")"
  if [ -n "$code" ] && [ -z "$tests" ]; then
    # Waived for this tip? (explicit, logged — never silent)
    if [ -f "$ledger" ] && grep "\"sha\":\"$sha\"" "$ledger" 2>/dev/null | grep -q '"verdict":"waived-tests:'; then
      continue
    fi
    code_without_tests="$code"
  fi
done <<EOF
$tips
EOF

[ -z "$code_without_tests" ] && exit 0

{
  echo "⛔ test gate — this chunk changes code with NO test change:"
  printf '%s\n' "$code_without_tests" | sed 's/^/    /'
  echo "Garth's standing rule (2026-07-16): tests for all the code we write."
  echo "Add or update a test (server/src/*.test.ts, clients/typescript/src/*.test.ts,"
  echo "scripts/*.test.js), or log an explicit waiver:"
  echo "  scripts/attest-review.sh \"waived-tests: <reason>\""
} >&2
exit 2
