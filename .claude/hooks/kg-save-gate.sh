#!/usr/bin/env bash
#
# kg-save-gate.sh — PreToolUse(Bash) hook for doxa-mcp-schema.
# Ported from doxa-cns / openclaw (Garth 2026-07-16 landing-gates suite;
# bootstrapped into this repo 2026-08-11).
#
# Garth's standing rule: "kg-save on every chunk." This hook is the ENFORCEMENT
# for that rule so it never depends on the model remembering — it survives
# fresh cron/headless sessions.
#
# It gates the chunk-LANDING commands (git push / gh pr create / gh pr merge):
# if the work about to land on main (origin/main..HEAD) contains no change to
# .knowledge-graph/, the landing is blocked with guidance to run kg-save first.
#
# Design choices:
#   * Gates at landing, not per micro-commit — review fix commits would
#     otherwise spam reminders. The real failure is a chunk hitting main with
#     no KG record.
#   * FAIL-OPEN. Any uncertainty (no payload, no jq, no origin/main, not a git
#     repo) -> exit 0 (allow). A buggy hook must never wedge an autonomous
#     build. Only a *confirmed* "landing command + zero KG change" blocks.
#   * This repo has no generated-state surfaces analogous to openclaw's
#     workspaces/cron/memory — the only landing-doesn't-need-kg-save
#     exemption is the KG's own state (.knowledge-graph/*).
#   * Escape hatch: the literal token [skip-kg] anywhere in the command
#     bypasses (for the rare push that is genuinely not a chunk landing).
#
# Exit codes (Claude Code hook contract): 0 = allow, 2 = block (stderr shown
# to the model), anything else = non-blocking error (tool still proceeds).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
# ---------------------------------------------------------------------------
# GitHub MCP merge path.
#
# THE HOLE THIS CLOSES (see openclaw/doxa-cns 2026-08-01). A gate registered
# for PreToolUse matcher "Bash" only never sees a PR merged through
# mcp__github__merge_pull_request — the payload has no .tool_input.command.
# Garth 2026-08-01: work done ANYWHERE is kg-saved when it is committed and
# merged to main, through the recursive quality gate.
#
# Escape hatch: there is no [skip-kg] token to attach to an MCP call, so a
# genuinely KG-less merge is done through Bash instead
# (`gh pr merge N --squash  # [skip-kg]`), which stays visible in the transcript.
# ---------------------------------------------------------------------------
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
if [ "$tool_name" = "mcp__github__merge_pull_request" ]; then
  mcp_repo="$(printf '%s' "$payload" | jq -r '.tool_input.repo // empty' 2>/dev/null)"
  [ "$mcp_repo" = "doxa-mcp-schema" ] || exit 0   # gate only this repo; siblings pass

  # Ask GitHub what this PR actually contains, rather than inferring it from
  # local state (a stale unrelated worktree with a KG commit would otherwise
  # satisfy the gate for EVERY merge — measured in doxa-cns 2026-08-01).
  pr_number="$(printf '%s' "$payload" | jq -r '(.tool_input.pullNumber // empty) | if type == "number" then floor else . end' 2>/dev/null)"
  mcp_owner="$(printf '%s' "$payload" | jq -r '.tool_input.owner // empty' 2>/dev/null)"
  case "$pr_number" in ''|*[!0-9]*) exit 0 ;; esac   # no usable PR number -> allow
  [ -n "$mcp_owner" ] || exit 0
  command -v gh >/dev/null 2>&1 || exit 0

  # Fail-open on any lookup trouble (offline, auth expired, API hiccup): a gate
  # that cannot see must not block. Only a CONFIRMED KG-less PR blocks.
  pr_files="$(gh pr diff "$pr_number" --repo "$mcp_owner/$mcp_repo" --name-only 2>/dev/null)" || exit 0
  [ -n "$pr_files" ] || exit 0

  printf '%s\n' "$pr_files" | grep -q '^\.knowledge-graph/' && exit 0

  {
    echo "⛔ kg-save gate — the chunk being merged has NO change to .knowledge-graph/."
    echo "Garth's standing rule is \"kg-save on every chunk\", and it applies to MCP merges too."
    echo "Record the KG learning on the branch, push, then merge:"
    echo
    echo "  node scripts/knowledge-graph-merkle.js add \"<Entity>\" \"<observation>\" \"<file>\" <line> --type <Type>"
    echo "  git add .knowledge-graph/graph.json .knowledge-graph-merkle.json"
    echo "  git commit -m \"chore(kg): <what changed and why>\" && git push"
    echo
    echo "(Genuinely not a chunk landing? Merge via Bash with [skip-kg] in the command.)"
  } >&2
  exit 2
fi

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

# Escape hatch.
case "$cmd" in
  *"[skip-kg]"*) exit 0 ;;
esac

# Only gate genuine chunk-LANDING commands. Match the landing verb at COMMAND
# POSITION (start of string, after optional VAR=val assignments and git/gh
# options incl. `-C <path>` / `-c <k=v>`) — NOT as a substring — so
# `git commit -m '…git push…'` and `grep -r 'git push'` are not spuriously
# blocked. Known fail-open residual (under-block, never over-block): a landing
# buried in a compound (`cd x && git push`) — handled below for cd-prefixes.
printf '%s' "$cmd" | grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*(git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push([[:space:];&|>]|$)|gh[[:space:]]+pr[[:space:]]+(create|merge)([[:space:];&|>]|$))' || exit 0

# The command runs in the Bash tool's PERSISTENT cwd, which may be a different
# repo than doxa-mcp-schema. This gate enforces "kg-save on every chunk" for
# doxa-mcp-schema landings ONLY — it must never block a sibling repo's push.
# Use the hook payload's cwd over CLAUDE_PROJECT_DIR, but if the command cd's
# into an absolute path or uses `git -C <path> … push`, evaluate THAT repo
# instead (the -C path only counts when attached to the git invocation that
# itself carries the push — see doxa-cns 2026-07-15 fix).
hook_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
cmd_gitC_clause="$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+(-[^C[:space:]][^[:space:]]*[[:space:]]+)*-C[[:space:]]+/[^[:space:];&|]+[^;&|]*[[:space:]]push' | head -1)"
cmd_gitC="$(printf '%s' "$cmd_gitC_clause" | grep -oE -- '-C[[:space:]]+/[^[:space:];&|]+' | head -1 | sed -E 's#-C[[:space:]]+##')"
cmd_cd="$(printf '%s' "$cmd" | grep -oE '(^|[;&|]|[[:space:]])cd[[:space:]]+/[^[:space:];&|]+' | head -1 | sed -E 's#.*cd[[:space:]]+##')"
if [ -n "$cmd_gitC" ] && [ -d "$cmd_gitC" ]; then
  dir="$cmd_gitC"
elif [ -n "$cmd_cd" ] && [ -d "$cmd_cd" ]; then
  dir="$cmd_cd"
else
  dir="${hook_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
fi
cd "$dir" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Only gate the doxa-mcp-schema repo itself; allow landings on other repos.
# Compare via --git-common-dir (resolves the MAIN checkout's .git dir for any
# linked worktree of the same repo), NOT --show-toplevel.
repo_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
proj_common="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
[ -n "$proj_common" ] && [ "$repo_common" != "$proj_common" ] && exit 0

# Base this chunk diverged from. No origin/main ref -> can't reason -> allow.
base="$(git merge-base HEAD origin/main 2>/dev/null)" || exit 0
[ -n "$base" ] || exit 0

# Empty range (HEAD at or behind origin/main) -> nothing is landing -> allow.
[ "$base" = "$(git rev-parse HEAD 2>/dev/null)" ] && exit 0

# Merge-integrity check (2026-08-13, Garth: "standing doctrine and practice
# across all repos"). Orthogonal to the "does this range have a kg-save at
# all" checks below: it does not ask whether a kg-save happened, it asks
# whether a MERGE inside this range LOST one that already did (real
# incident: a .knowledge-graph-merkle.json conflict resolved with
# `git checkout --theirs` silently discarded a branch's own observation —
# the observations array is an append log, so picking one side of a
# conflict can only ever keep a subset). Fail-open on any tooling trouble.
if [ -f "$dir/scripts/check-kg-merge-integrity.js" ] && command -v node >/dev/null 2>&1; then
  integrity_output="$(node "$dir/scripts/check-kg-merge-integrity.js" "$base" HEAD 2>&1)"
  integrity_status=$?
  if [ "$integrity_status" -eq 1 ]; then
    printf '%s\n' "$integrity_output" >&2
    exit 2
  fi
fi


# The only surface that never requires kg-save is the KG's own generated
# state. Unlike openclaw, this repo has no workspaces/cron/memory generated
# surfaces — everything else hand-authored counts.
hand_authored=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    .knowledge-graph/*|.knowledge-graph-merkle.json) continue ;;
  esac
  hand_authored="yes"
  break
done <<EOF
$(git diff --name-only "$base" HEAD 2>/dev/null)
EOF
[ -z "$hand_authored" ] && exit 0

# Already a KG change in this chunk's range? -> allow.
if ! git diff --quiet "$base" HEAD -- .knowledge-graph/ 2>/dev/null; then
  exit 0
fi

# Worktree-aware pass (PR-first landings may push from scratch worktrees): if
# ANY worktree of this repo has a non-empty origin/main..HEAD range that
# includes a .knowledge-graph/ change -> allow (under-block, never over-block).
while IFS= read -r wt; do
  [ -d "$wt" ] || continue
  wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || continue
  wt_base="$(git -C "$wt" merge-base HEAD origin/main 2>/dev/null)" || continue
  [ "$wt_base" = "$wt_head" ] && continue   # nothing landing from this worktree
  if ! git -C "$wt" diff --quiet "$wt_base" "$wt_head" -- .knowledge-graph/ 2>/dev/null; then
    exit 0
  fi
done <<EOF
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
EOF

# Confirmed: a landing command with zero .knowledge-graph/ change in origin/main..HEAD.
{
  echo "⛔ kg-save gate — this chunk (origin/main..HEAD) has NO change to .knowledge-graph/."
  echo "Garth's standing rule is \"kg-save on every chunk.\" Record the KG learning before landing:"
  echo
  echo "  node scripts/knowledge-graph-merkle.js add \"<Entity>\" \"<observation>\" \"<file>\" <line> --type <Type>"
  echo "  git add .knowledge-graph/graph.json .knowledge-graph-merkle.json"
  echo "  git commit -m \"<AgentName>: kg-save — <what changed and why>\""
  echo
  echo "Then re-run this command. (Genuinely not a chunk landing? Add [skip-kg] to the command to bypass.)"
} >&2
exit 2
