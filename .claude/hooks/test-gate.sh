#!/usr/bin/env bash
#
# test-gate.sh — PreToolUse hook for the GitHub MCP merge tool (and Bash
# `gh pr merge` where settings.json wires it on the Bash matcher).
#
# Garth's standing rule (2026-07-16): "tests for all the code we write."
# A doxa-mcp-schema PR merge is blocked when the chunk (merge-base(origin/main,
# tip)..tip, for the landing tip — see "Which tip" below) adds or modifies
# code — this repo's code_re, minus its test_re and code_exclude_re (set per
# repo in doxa-cns config/fleet.yaml `gates:`) — while changing NO test file
# (test_re). The escape hatch is an EXPLICIT logged waiver in the shared
# attestation ledger: scripts/attest-review.sh "waived-tests: <reason>".
#
# ESM coverage (2026-07-19): the pattern was `\.js$`, blind to the fleet's
# .mjs detectors (7 in gated dirs) — they could merge untested with the gate
# none the wiser. Broadened to `\.(c|m)?js$` so .js/.mjs/.cjs all count.
# A test_re that matches NOTHING turns this gate into a no-op (doxa-discord-bot
# sat green that way until 2026-08-15): keep each repo's patterns in step with
# the files its test runner really executes.
#
# FAIL-OPEN philosophy (matches kg-save-gate.sh / review-gate.sh): any
# uncertainty allows. Only the confirmed case blocks: code changed, zero test
# changes, zero waiver for the tip. Docs, vault, generated state, YAML, and
# shell hooks (exercised by live self-tests, not the node runner) never
# trigger it.
#
# BASH surface + repo attribution: identical to review-gate.sh (see there).
#
# Exit codes: 0 = allow, 2 = block (stderr shown to the model).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# bounded <secs> <cmd…> — the gh calls below are bounded (as kg-save-gate.sh):
# a stalled gh would hold the merge until the harness's hook timeout. macOS has
# no `timeout` unless coreutils is installed; without one the call runs as before.
bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"
  fi
}

# This repo's names, any case (rename doxa-cns -> The-Doxa-Way-CNS, spec S1/S2).
self_id="$(printf '%s' 'doxa-mcp-schema' | tr '[:upper:]' '[:lower:]')"
self_slug="$(printf '%s' 'doxa-mcp-schema' | tr '[:upper:]' '[:lower:]')"
is_self() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#/pull/[0-9]+.*$##; s#/+$##; s#\.git$##; s#^.*[/:]##')"
  [ -n "$n" ] && { [ "$n" = "$self_id" ] || [ "$n" = "$self_slug" ]; }
}

code_re='^(server/src/.+\.ts|server/scripts/.+\.mjs|clients/typescript/src/.+\.ts|scripts/.+\.(js|mjs|sh))$'
test_re='^(server/src/.+\.test\.ts|server/test/.+|clients/typescript/src/.+\.test\.ts|clients/typescript/test/.+|scripts/.+\.test\.(js|mjs))$'
code_exclude_re=''   # empty = nothing excluded

repo="$(printf '%s' "$payload" | jq -r '.tool_input.repo // empty' 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"

# The PR being merged (same parse as review-gate.sh).
pr_ref="$(printf '%s' "$payload" | jq -r '(.tool_input.pullNumber // .tool_input.pull_number // empty) | tostring' 2>/dev/null)"
if [ -z "$pr_ref" ] && [ -n "$cmd" ]; then
  pr_cmd="$(printf '%s' "$cmd" | tr -d "\"'(){}\`")"
  set -f
  # shellcheck disable=SC2086
  set -- $pr_cmd
  set +f
  while [ $# -ge 3 ] && ! { [ "$1" = "gh" ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; }; do shift; done
  if [ $# -ge 3 ]; then shift 3; else set --; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|-R|--body|-b|--body-file|-F|--subject|-t|--match-head-commit|--author-email|-A) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      '&&'|';'|'|'|'||') break ;;
      *) pr_ref="${1%%[;&|]*}"; break ;;
    esac
  done
fi

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
flag_repo=""
landing=merge

if [ -n "$repo" ]; then
  # MCP merge tool: gate only this repo; siblings pass.
  is_self "$repo" || exit 0
elif [ -n "$cmd" ]; then
  scan="$(printf '%s' "$cmd" | tr -d "\"'")"
  landing=""
  if printf '%s' "$scan" | grep -qE '(^|[;&|(){}`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|>)]|$)'; then
    landing=merge
  fi
  [ -n "$landing" ] || exit 0   # not a landing command

  flag_repo="$(printf '%s' "$scan" | grep -oE -- '(-R|--repo)([[:space:]]+|=)[^[:space:];&|)]+' | head -1 | sed -E 's/^(-R|--repo)([[:space:]]+|=)//')"
  [ -n "$flag_repo" ] || flag_repo="$(printf '%s' "$scan" | grep -oE '(^|[;&|[:space:]])GH_REPO=[^[:space:];&|]+' | head -1 | sed -E 's/^.*GH_REPO=//')"
  if [ -z "$flag_repo" ]; then
    case "$pr_ref" in
      https://github.com/*/*/pull/*|github.com/*/*/pull/*) flag_repo="$pr_ref" ;;
    esac
  fi
  if [ -n "$flag_repo" ]; then
    is_self "$flag_repo" || exit 0   # sibling repo — their gates, not ours
  else
    hook_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    [ -n "$hook_cwd" ] && dir="$hook_cwd"
    remaining="$scan"
    while [[ "$remaining" =~ ^[[:space:]]*cd[[:space:]]+([^\;\&]+)(\&\&|\;)(.*)$ ]]; do
      cmd_cd="$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/[[:space:]]+$//')"
      case "$cmd_cd" in
        '~') cmd_cd="$HOME" ;;
        '~/'*) cmd_cd="$HOME/${cmd_cd#\~/}" ;;
        /*) : ;;
        *) [ -n "$hook_cwd" ] && [ -d "$hook_cwd" ] && cmd_cd="$hook_cwd/$cmd_cd" ;;
      esac
      [ -n "$cmd_cd" ] && [ -d "$cmd_cd" ] && dir="$cmd_cd"
      remaining="${BASH_REMATCH[3]}"
    done
    target_origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    case "$target_origin" in
      *github.com[:/]*) is_self "$target_origin" || exit 0 ;;
      *)
        repo_common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
        proj_common="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        [ -n "$repo_common" ] && [ -n "$proj_common" ] || exit 0
        [ "$repo_common" = "$proj_common" ] || exit 0
        ;;
    esac
  fi
else
  exit 0
fi

cd "$dir" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
ledger="$common/review-attest.jsonl"

# Which tip does this merge land? When the caller names the PR head
# (bash-merge-gate.sh passes a top-level .merge_gate_head_sha), judge ONLY that tip: judging
# every local worktree tip let another session's untested sibling worktree
# block an unrelated, fully tested PR (#720, 2026-09-24 doxa-cns #938; doxa-app
# #1142, 2026-08-24). Fetch the head if it isn't local. If it still can't be
# resolved, fall back to the old all-tips scan -- never a weaker check than
# before. Top level, never .tool_input: the MCP merge hook hands this gate the
# tool call's own input, so a head_sha there would let the caller name a tested
# commit other than the PR's. Without a wrapper, the head comes from GitHub
# itself (`gh pr view` on the PR being merged — doxa-app / browser-extension
# fix), never from caller-supplied text.
head_sha="$(printf '%s' "$payload" | jq -r '.merge_gate_head_sha // empty' 2>/dev/null)"
gh_slug=""
if [ -n "$pr_ref" ] && command -v gh >/dev/null 2>&1; then
  gh_slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
  case "$flag_repo" in
    */*) gh_slug="$(printf '%s' "$flag_repo" | sed -E 's#^https?://##; s#^github\.com/##; s#/pull/.*$##; s#\.git$##')" ;;
  esac
  if [ -z "$head_sha" ] && [ -n "$gh_slug" ]; then
    head_sha="$(bounded 15 gh pr view "$pr_ref" --repo "$gh_slug" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  fi
fi
tips=""
if printf '%s' "$head_sha" | grep -qE '^[0-9a-f]{40}$'; then
  # Bounded (review round): this fetch is new I/O the #720 fix introduced.
  # A stalled origin would otherwise run until the hook's own timeout, which
  # (per this file's own documented fail-open philosophy) merges unchecked
  # rather than blocking -- so keep the stall itself short.
  git cat-file -e "$head_sha^{commit}" 2>/dev/null \
    || git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
         fetch -q origin "$head_sha" >/dev/null 2>&1 || true
  git cat-file -e "$head_sha^{commit}" 2>/dev/null && tips="$head_sha"
fi
# Chained `git push && gh pr merge N` race: bash-merge-gate.sh resolves
# head_sha from the PRE-push remote tip, stale the instant the chained push
# moves it. When it detected a leading push, it also hands us THIS
# worktree's own current HEAD (never sibling worktrees -- #720) so the
# about-to-be-pushed tip is judged too, not just the stale remote one.
local_head_sha="$(printf '%s' "$payload" | jq -r '.merge_gate_local_head_sha // empty' 2>/dev/null)"
if [ -n "$tips" ] && [ "$local_head_sha" != "$head_sha" ] \
   && printf '%s' "$local_head_sha" | grep -qE '^[0-9a-f]{40}$' \
   && git cat-file -e "$local_head_sha^{commit}" 2>/dev/null; then
  tips="$tips
$local_head_sha"
fi
# A direct push lands THIS worktree's HEAD — the exact tip, no fallback needed.
[ "$landing" = push ] && tips="$(git rev-parse HEAD 2>/dev/null)"
# The PR's real file list when its head is NOT judgeable locally (unfetchable):
# judged on GitHub's own list below, IN ADDITION to the all-tips fallback
# (browser-extension / discord-bot fix — a local tip cannot be trusted to be
# the PR being merged).
remote_changed=""
if [ -z "$tips" ] && [ -n "$pr_ref" ] && [ -n "$gh_slug" ]; then
  remote_changed="$(bounded 15 gh pr diff "$pr_ref" --repo "$gh_slug" --name-only 2>/dev/null || true)"
fi
# Otherwise: HEAD plus every worktree tip; the merge could land any of them.
[ -n "$tips" ] || tips="$(git rev-parse HEAD 2>/dev/null)
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^HEAD //p')"

# code_of / tests_of <changed-file list>: this repo's code and test files.
code_of() {
  local c
  c="$(printf '%s\n' "$1" | grep -vE "$test_re" | grep -E "$code_re")"
  [ -n "$code_exclude_re" ] && c="$(printf '%s\n' "$c" | grep -vE "$code_exclude_re")"
  printf '%s' "$c"
}
tests_of() { printf '%s\n' "$1" | grep -E "$test_re"; }

code_without_tests=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  base="$(git merge-base "$sha" origin/main 2>/dev/null)" || continue
  [ "$base" = "$sha" ] && continue   # nothing landing from this tip
  changed="$(git diff --name-only "$base" "$sha" 2>/dev/null)" || continue

  code="$(code_of "$changed")"
  tests="$(tests_of "$changed")"
  if [ -n "$code" ] && [ -z "$tests" ]; then
    # Waived for this tip? (explicit, logged — never silent).
    if [ -f "$ledger" ] && grep -q "\"sha\":\"$sha\"" "$ledger" 2>/dev/null \
       && grep "\"sha\":\"$sha\"" "$ledger" | grep -q '"verdict":"waived-tests:' 2>/dev/null; then
      continue
    fi
    code_without_tests="$(printf '%s\n%s' "$code_without_tests" "$code")"
  fi
done <<EOF
$tips
EOF

if [ -n "$remote_changed" ]; then
  code="$(code_of "$remote_changed")"
  tests="$(tests_of "$remote_changed")"
  if [ -n "$code" ] && [ -z "$tests" ]; then
    if ! { printf '%s' "$head_sha" | grep -qE '^[0-9a-f]{40}$' && [ -f "$ledger" ] \
           && grep "\"sha\":\"$head_sha\"" "$ledger" 2>/dev/null | grep -q '"verdict":"waived-tests:'; }; then
      code_without_tests="$(printf '%s\n%s' "$code_without_tests" "$code")"
    fi
  fi
fi

[ -z "$code_without_tests" ] && exit 0

{
  echo "⛔ test gate — this chunk changes code with NO test change:"
  printf '%s\n' "$code_without_tests" | sed '/^$/d; s/^/    /' | sort -u
  echo "Garth's standing rule (2026-07-16): tests for all the code we write."
  echo 'Add or update a test (server/src/*.test.ts, clients/typescript/src/*.test.ts, scripts/*.test.js), or log an explicit waiver:'
  echo "  scripts/attest-review.sh \"waived-tests: <reason>\""
} >&2
exit 2
