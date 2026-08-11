#!/usr/bin/env bash
#
# review-gate.sh — PreToolUse gate on landing a doxa-mcp-schema PR merge.
# Ported from doxa-cns (Garth 2026-07-16 landing-gates suite).
#
# Garth's standing rule: every chunk lands only after an INDEPENDENT review
# pass (PR bot / /code-review by a non-author session — self-review never
# counts, see CLAUDE.md "Landing doctrine"). This hook ENFORCES it instead of
# remembering it: a doxa-mcp-schema PR merge — via mcp__github__merge_pull_request
# OR a Bash `gh pr merge` — is blocked unless the review attestation ledger
# ($GIT_COMMON_DIR/review-attest.jsonl, written by scripts/attest-review.sh)
# contains an entry for the tip of a local branch/worktree, i.e. the code
# being merged was reviewed AT its final SHA, not at some earlier state.
#
# FAIL-OPEN philosophy: any uncertainty — no payload, no jq, repo not
# doxa-mcp-schema, git lookups failing — allows the call. Only the confirmed
# case blocks: a doxa-mcp-schema merge with no attestation matching any local
# tip. The escape hatch is an EXPLICIT logged waiver
# (scripts/attest-review.sh "waived: <reason>"), never a silent bypass.
#
# Exit codes: 0 = allow, 2 = block (stderr shown to the model).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

repo="$(printf '%s' "$payload" | jq -r '.tool_input.repo // empty' 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"

dir="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ -n "$repo" ]; then
  # MCP merge tool (mcp__github__merge_pull_request): gate only this repo.
  [ "$repo" = "doxa-mcp-schema" ] || exit 0
elif [ -n "$cmd" ]; then
  # Bash tool: gate only a `gh pr merge` at command position (optionally after
  # a `cd <path> &&` prefix and env assignments) — never as a substring, so
  # `git commit -m '…gh pr merge…'` is not spuriously blocked. Under-block,
  # never over-block: a merge buried deeper in a compound passes (fail-open).
  printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cd[[:space:]]+[^;&|]+(&&|;)[[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|>]|$)' || exit 0

  # Which repo is being merged? -R/--repo flag wins; else resolve the working
  # directory (cd-prefix path over payload cwd) and require it to be THIS repo.
  flag_repo="$(printf '%s' "$cmd" | grep -oE '(-R|--repo)([[:space:]]+|=)[^[:space:];&|]+' | head -1 | sed -E 's/^(-R|--repo)([[:space:]]+|=)//')"
  if [ -n "$flag_repo" ]; then
    case "$flag_repo" in
      doxa-mcp-schema|*/doxa-mcp-schema) ;;   # gate
      *) exit 0 ;;                        # sibling repo — pass
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
    [ "$repo_common" = "$proj_common" ] || exit 0   # different repo — pass
  fi
else
  exit 0
fi

cd "$dir" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
ledger="$common/review-attest.jsonl"

# Candidate SHAs the merge could be landing: HEAD plus every worktree tip.
tips="$(git rev-parse HEAD 2>/dev/null)
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^HEAD //p')"

if [ -f "$ledger" ]; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if grep "\"sha\":\"$sha\"" "$ledger" 2>/dev/null | grep -qv '"verdict":"waived-tests:'; then
      exit 0
    fi
  done <<EOF
$tips
EOF
fi

{
  echo "⛔ review gate — no review attestation for any local branch tip."
  echo "Every doxa-mcp-schema chunk merges only after its INDEPENDENT review pass (CLAUDE.md Landing doctrine — self-review never counts)."
  echo "Run the review on the final diff, fix findings, then attest and retry:"
  echo
  echo "  PR bot / /code-review (non-author) → fix round →"
  echo "  scripts/attest-review.sh \"clean\"   (or \"findings-fixed: <summary>\")"
  echo
  echo "Genuinely reviewless landing (generated state only)? Log an explicit waiver:"
  echo "  scripts/attest-review.sh \"waived: <reason>\""
} >&2
exit 2
