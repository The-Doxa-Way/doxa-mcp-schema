#!/usr/bin/env bash
#
# review-gate.sh — PreToolUse hook for the GitHub MCP merge tool (and Bash
# `gh pr merge` where settings.json wires it on the Bash matcher).
#
# Garth's standing rule (2026-07-16): every doxa-mcp-schema chunk lands through the
# recursive-quality-gate with an independent review pass — and that must be
# ENFORCED, not remembered. The kg-save gate only sees Bash commands; PR merges
# issued through mcp__github__merge_pull_request bypassed every hook. This
# gate closes that hole: a doxa-mcp-schema PR merge is blocked unless the review
# attestation ledger ($GIT_COMMON_DIR/review-attest.jsonl, written by
# scripts/attest-review.sh after the /code-review pass) contains an entry for
# the tip of a local branch/worktree — i.e. the code being merged was reviewed
# AT its final SHA, not at some earlier state.
#
# FAIL-OPEN philosophy (matches kg-save-gate.sh): any uncertainty — no payload,
# no jq, repo field missing or not doxa-mcp-schema, git lookups failing — allows the
# call. Only the confirmed case blocks: a doxa-mcp-schema merge with no attestation
# matching any local tip. The escape hatch is an EXPLICIT logged waiver
# (scripts/attest-review.sh "waived: <reason>"), never a silent bypass.
#
# BASH surface (fleet union, 2026-11-05 — from the openclaw, doxa-shared,
# doxa-app, browser-extension and discord-bot copies): a Bash payload
# (tool_input.command) is gated when it runs `gh pr merge` at a command
# position — start, or after ; & | ( ) { } or a backtick — with quote
# characters stripped first, so `gh "pr" merge` and `(gh pr merge …)` are
# caught, while a mention inside one quoted argument (`git commit -m '…gh pr
# merge…'`) is not. Repo attribution: --repo/-R, GH_REPO=, or a PR URL as the
# merge's own ref decides; else the directory the command runs in (last
# leading `cd`, else payload.cwd): a GitHub origin decides by name, any other
# origin by git-common-dir. doxa-cns wires only the MCP matcher here and sends
# Bash merges through bash-merge-gate.sh, which re-invokes this hook with an
# MCP-shaped payload, so this branch is inert there.
#
# PORTABLE / CONTENT-KEY match (CEO ruling, 2026-09-11): the exact-SHA loop
# below is kept as-is (existing jsonl rows and every waiver still work
# unchanged). In addition, a tip whose CONTENT key (a normalised hash of the
# diff against the merge-base — stable across a rebase or merging the base
# in, but NOT blind to whitespace, see scripts/lib/review-attest.js) matches
# a VALID attestation note on refs/notes/review-attest also passes, even when
# the SHA itself was never directly attested (e.g. main got merged in after
# attest-review.sh ran). Same fail-open rule applies: no node, no script, or
# a lookup error just means this avenue found nothing — it never blocks by
# itself, and never forces a pass either. A forged/mismatched note is
# rejected by the library's own validateNote check, not by anything here.
# Repos without scripts/review-attest-check.mjs skip this avenue at runtime.
#
# ONE node process for ALL tips (review finding HIGH-3, 2026-09-11): this
# used to spawn the checker once per worktree tip (18 of them here), each
# rebuilding the whole note index and running a full diff per note. That
# degraded toward a no-op as notes accumulated — the hook would hit the
# harness timeout, and a KILLED hook does not return exit 2, so the merge
# would proceed. The checker now takes repeatable --head and shares one
# note index across every tip.
#
# Deliberately NO --require-reviewed here: `attest-review.sh "waived: …"` is
# the documented LOCAL escape hatch and must keep working. CI passes that
# flag instead, so a self-issued waiver can never suppress the model review.
#
# Exit codes: 0 = allow, 2 = block (stderr shown to the model).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# This repo's names, any case: the fleet key and the GitHub slug. They differ
# only for doxa-cns (rename doxa-cns -> The-Doxa-Way-CNS, spec S1/S2); both
# must keep matching.
self_id="$(printf '%s' 'doxa-mcp-schema' | tr '[:upper:]' '[:lower:]')"
self_slug="$(printf '%s' 'doxa-mcp-schema' | tr '[:upper:]' '[:lower:]')"
# is_self <name>: a bare name, owner/name, or GitHub URL (https or ssh, with
# or without .git or a /pull/N suffix) that names THIS repo.
is_self() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#/pull/[0-9]+.*$##; s#/+$##; s#\.git$##; s#^.*[/:]##')"
  [ -n "$n" ] && { [ "$n" = "$self_id" ] || [ "$n" = "$self_slug" ]; }
}

repo="$(printf '%s' "$payload" | jq -r '.tool_input.repo // empty' 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"

# The PR being merged: the MCP tool's pullNumber, else the first positional of
# `gh pr merge` (number, URL or branch; flags may come first). Quotes are
# stripped so a quoted ref still parses. Anchored on the `gh pr merge` token
# triple, not the first `merge` word: `git merge x && gh pr merge 5` must
# resolve PR 5, never branch x.
rg_pr_ref="$(printf '%s' "$payload" | jq -r '(.tool_input.pullNumber // .tool_input.pull_number // empty) | tostring' 2>/dev/null)"
if [ -z "$rg_pr_ref" ] && [ -n "$cmd" ]; then
  rg_cmd="$(printf '%s' "$cmd" | tr -d "\"'(){}\`")"
  set -f
  # shellcheck disable=SC2086
  set -- $rg_cmd
  set +f
  while [ $# -ge 3 ] && ! { [ "$1" = "gh" ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; }; do shift; done
  if [ $# -ge 3 ]; then shift 3; else set --; fi   # no `gh pr merge` → no ref
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|-R|--body|-b|--body-file|-F|--subject|-t|--match-head-commit|--author-email|-A) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      '&&'|';'|'|'|'||') break ;;
      *) rg_pr_ref="${1%%[;&|]*}"; break ;;
    esac
  done
fi

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
flag_repo=""

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

  # Which repo? --repo/-R/--repo=, an inline GH_REPO=, or a PR URL that IS the
  # merge's own ref (never a URL merely mentioned elsewhere, e.g. in --body).
  flag_repo="$(printf '%s' "$scan" | grep -oE -- '(-R|--repo)([[:space:]]+|=)[^[:space:];&|)]+' | head -1 | sed -E 's/^(-R|--repo)([[:space:]]+|=)//')"
  [ -n "$flag_repo" ] || flag_repo="$(printf '%s' "$scan" | grep -oE '(^|[;&|[:space:]])GH_REPO=[^[:space:];&|]+' | head -1 | sed -E 's/^.*GH_REPO=//')"
  if [ -z "$flag_repo" ]; then
    case "$rg_pr_ref" in
      https://github.com/*/*/pull/*|github.com/*/*/pull/*) flag_repo="$rg_pr_ref" ;;
    esac
  fi
  if [ -n "$flag_repo" ]; then
    is_self "$flag_repo" || exit 0   # sibling repo — their gates, not ours
  else
    # gh resolves the repo from the directory the command runs in: the LAST
    # leading `cd <path> &&`/`;` hop (~ and relative paths resolved), else the
    # Bash tool's real cwd (payload.cwd), else CLAUDE_PROJECT_DIR.
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
      *github.com[:/]*) is_self "$target_origin" || exit 0 ;;   # a GitHub origin decides by name
      *)
        repo_common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
        proj_common="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        [ -n "$repo_common" ] && [ -n "$proj_common" ] || exit 0
        [ "$repo_common" = "$proj_common" ] || exit 0   # different repo — pass
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

# Candidate SHAs the merge could be landing: HEAD plus every worktree tip.
tips="$(git rev-parse HEAD 2>/dev/null)
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^HEAD //p')"
# PR head resolution (gate-health NO_PR_HEAD_RESOLUTION, 2026-10-24). With
# only the local tips above, ANY attested local branch admitted ANY PR by
# number. Narrow the candidates to the merged PR's real head SHA: a wrapper
# hook's merge_gate_head_sha first, else `gh pr view` on the PR ref parsed
# above. If the head cannot be resolved (no PR ref, gh missing or offline),
# keep the local tips: fail-open, exactly the old behaviour, never a false
# block from an outage.
remote_head_sha="$(printf '%s' "$payload" | jq -r '.merge_gate_head_sha // empty' 2>/dev/null)"
if [ -z "$remote_head_sha" ] && [ -n "$rg_pr_ref" ] && command -v gh >/dev/null 2>&1; then
  rg_slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
  case "$flag_repo" in
    */*) rg_slug="$(printf '%s' "$flag_repo" | sed -E 's#^https?://##; s#^github\.com/##; s#/pull/.*$##; s#\.git$##')" ;;
  esac
  if [ -n "$rg_slug" ]; then
    remote_head_sha="$(gh pr view "$rg_pr_ref" --repo "$rg_slug" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  fi
fi
case "$remote_head_sha" in
  *[!0-9a-f]*|'') ;;
  *) [ "${#remote_head_sha}" = 40 ] && tips="$remote_head_sha" ;;
esac

# A tip a review BLOCKED (attest-review.sh "blocked: …", review-blocked.jsonl)
# attests nothing, by SHA or by tree: an attestation or content-key note made
# before the block, or for the same code under a new SHA, cannot land it
# (Wamemba me's no-re-review rule, S4a). Dropped, not blocked outright: another
# local tip is still judged on its own, exactly as before.
blocked_ledger="$common/review-blocked.jsonl"
if [ -f "$blocked_ledger" ]; then
  kept=""
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    tree="$(git rev-parse -q --verify "$sha^{tree}" 2>/dev/null || true)"
    if grep -qF "\"sha\":\"$sha\"" "$blocked_ledger" \
       || { [ -n "$tree" ] && grep -qF "\"tree\":\"$tree\"" "$blocked_ledger"; }; then
      continue
    fi
    kept="$kept$sha
"
  done <<EOF
$tips
EOF
  tips="$kept"
fi

if [ -f "$ledger" ]; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # A REVIEW verdict (clean / findings-fixed: / waived:) — NOT a test-only
    # waiver. review-gate and test-gate share one ledger + one attest script,
    # so a bare sha match would let `attest-review.sh "waived-tests: …"` (a
    # TEST waiver, no review implied) satisfy the REVIEW gate too, bypassing
    # both gates with one line. Require at least one entry for this tip whose
    # verdict is not `waived-tests:`.
    if grep "\"sha\":\"$sha\"" "$ledger" 2>/dev/null | grep -qv '"verdict":"waived-tests:'; then
      exit 0
    fi
  done <<EOF
$tips
EOF
fi

# CONTENT-key match (portable evidence): a tip whose diff-against-merge-base
# matches a valid, non-waived-tests attestation note also passes, even when
# the exact SHA was never itself attested (rebase / merge-the-base-in since
# attest-review.sh ran). Best-effort — no node or the checker script missing
# just means this avenue found nothing, same as an empty ledger above.
checker="$(dirname "${BASH_SOURCE[0]}")/../../scripts/review-attest-check.mjs"
if command -v node >/dev/null 2>&1 && [ -f "$checker" ]; then
  head_args=()
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    head_args+=(--head "$sha")
  done <<EOF
$tips
EOF
  if [ "${#head_args[@]}" -gt 0 ]; then
    result="$(node "$checker" "${head_args[@]}" 2>/dev/null)" || result=""
    if [ -n "$result" ] && printf '%s' "$result" | jq -e '.reused == true' >/dev/null 2>&1; then
      exit 0
    fi
  fi
fi

{
  echo "⛔ review gate — no review attestation for any local branch tip."
  echo 'Every doxa-mcp-schema chunk merges only after its independent review pass (CLAUDE.md Landing doctrine — self-review never counts).'
  echo "Run the review on the final diff, fix findings, then attest and retry:"
  echo
  echo "  /code-review (per the chunk's tier) → fix round →"
  echo "  scripts/attest-review.sh \"clean\"   (or \"findings-fixed: <summary>\")"
  echo
  echo "Genuinely reviewless landing (generated state only)? Log an explicit waiver:"
  echo "  scripts/attest-review.sh \"waived: <reason>\""
} >&2
exit 2
