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
rg_pr_ref="$(printf '%s' "$payload" | jq -r '(.tool_input.pullNumber // .tool_input.pull_number // empty) | if type == "number" then floor else . end | tostring' 2>/dev/null)"
# gate_words <cmd>: the command with every quoted string that contains
# whitespace (a --subject/--body message) replaced by ONE token QMSG, and the
# quotes of the others removed. Message text is data: it must never become the
# merge's ref, a -R flag or a GH_REPO prefix (Vercel Security Review,
# 2026-11-05: `--body "GH_REPO=other/repo"` made a merge here look like a
# sibling's and skipped this gate). perl pairs quotes left to right. A
# double-quoted string that holds $(…) or `…` runs that command, so each
# substitution stays as its own command segment (" ; <inner> ; ") and only the
# rest of the message is dropped (Vercel Security Review, 2026-11-05: masking
# `"$(gh pr merge 5)"` hid the merge); an unbalanced one is kept whole. These
# words only choose the repo and the ref: whether the command lands is read
# from the quote-stripped command too, so the mask can never hide a merge. A
# quoted string keeps its text only when every character is a plain token
# character (a ref, a repo); anything else is QMSG, so its ; | ( or -R can
# never act as shell syntax or a flag.
gate_words() {
  printf '%s' "$1" | perl -0777 -pe 's/((?<!\\)\x27[^\x27]*\x27|(?<!\\)"(?:[^"\\]|\\.)*")/ my $q = $1; my @s; if ($q =~ m{^"} && $q =~ m{\$\(|`}) { while ($q =~ m{\$(\((?:[^()]++|(?1))*\))|`([^`]*)`}g) { push @s, defined $1 ? substr($1, 1, -1) : $2 } @s ? join("", map { " ; $_ ; " } @s) : substr($q, 1, -1) } elsif ($q =~ m{^.[A-Za-z0-9_.\/:@+=,%-]*.$}) { substr($q, 1, -1) } else { "QMSG" } /ge' 2>/dev/null \
    || printf '%s' "$1" | tr -d "\"'"
}
# merge_repo_flag <tokens…>: the value of -R/--repo given to `gh pr merge`
# itself (flags with values skipped), or nothing.
merge_repo_flag() {
  while [ $# -ge 3 ] && ! { [ "${1##*[(\{\`]}" = "gh" ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; }; do shift; done
  if [ $# -ge 3 ]; then shift 3; else return 0; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|-R) [ $# -gt 1 ] && printf '%s' "${2%%[;&|)]*}"; return 0 ;;
      --repo=*) local v="${1#--repo=}"; printf '%s' "${v%%[;&|)]*}"; return 0 ;;
      -R?*) local v="${1#-R}"; printf '%s' "${v%%[;&|)]*}"; return 0 ;;   # attached: -Rowner/repo
      --body|-b|--body-file|-F|--subject|-t|--match-head-commit|--author-email|-A) shift; [ $# -gt 0 ] && shift ;;
      -[!-]*R*) printf '?'; return 0 ;;   # -R in a flag cluster: unreadable, so it blocks
      '&&'|';'|'|'|'||') return 0 ;;
      *) shift ;;
    esac
  done
}
# merge_segment <raw> <words>: the one simple command that runs `gh pr merge`,
# cut from the masked words at every ; & | newline and backtick — empty when
# either form holds no merge or more than one, so nothing outside the merge's
# own command (a substitution's GH_REPO, an earlier `cd`, a second merge) can
# name its repo (Vercel Security Review, 2026-11-05).
merge_segment() {
  local segs
  [ "$(printf '%s' "$1" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge' | wc -l | tr -d ' ')" = 1 ] || return 0
  segs="$(printf '%s' "$2" | tr ';&|`' '\n\n\n\n' | grep -E '(^|[^A-Za-z0-9_-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]>)]|$)')"
  [ "$(printf '%s\n' "$segs" | grep -c .)" = 1 ] && printf '%s' "$segs"
  return 0
}
# seg_gh_repo <segment>: a GH_REPO= assignment prefixed to that segment's gh.
seg_gh_repo() {
  printf '%s' "$1" | sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*GH_REPO=([^[:space:]]+)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:]>].*)?$/\2/p'
}
# first_merge_ref <tokens…>: the first positional after `gh pr merge` (flags
# and their values skipped), or nothing. A leading `(`/`{`/backtick on `gh` is
# allowed, so a subshell or substitution still finds the merge.
first_merge_ref() {
  while [ $# -ge 3 ] && ! { [ "${1##*[(\{\`]}" = "gh" ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; }; do shift; done
  if [ $# -ge 3 ]; then shift 3; else return 0; fi   # no `gh pr merge` → no ref
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|-R|--body|-b|--body-file|-F|--subject|-t|--match-head-commit|--author-email|-A) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      '&&'|';'|'|'|'||') return 0 ;;
      *) printf '%s' "${1%%[;&|]*}"; return 0 ;;
    esac
  done
}
rg_ref_altered=0
if [ -z "$rg_pr_ref" ] && [ -n "$cmd" ]; then
  set -f
  # shellcheck disable=SC2046
  rg_words="$(gate_words "$cmd")"
  rg_pr_ref="$(first_merge_ref $(printf '%s' "$rg_words" | tr -d "(){}\`"))"
  # The ref must be the merge's own argument exactly as written. Deleting
  # (){}` turns a branch `a{b}` into `ab`, another PR whose attestation would
  # then pass for this merge (Vercel Security Review, 2026-11-05). Acted on
  # below, once the command is known to land in this repo.
  # Every ref, numbers and URLs too: `1{2}` strips to the number 12. A real
  # number or URL has none of those characters, so it compares equal.
  # shellcheck disable=SC2046
  [ -z "$rg_pr_ref" ] || [ "$(first_merge_ref $rg_words)" = "$rg_pr_ref" ] || rg_ref_altered=1
  [ "$rg_pr_ref" != QMSG ] || rg_ref_altered=1   # a quoted ref we would not read as-is
  set +f
fi

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
flag_repo=""

if [ -n "$repo" ]; then
  # MCP merge tool: gate only this repo; siblings pass.
  is_self "$repo" || exit 0
elif [ -n "$cmd" ]; then
  scan="$(gate_words "$cmd")"
  raw="$(printf '%s' "$cmd" | tr -d "\"'")"
  landing=""
  if printf '%s\n%s' "$raw" "$scan" | grep -qE '(^|[;&|(){}`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:];&|>)]|$)'; then
    landing=merge
  fi
  [ -n "$landing" ] || exit 0   # not a landing command

  # The merge contract (Vercel Security Review, 2026-11-05: five rounds found a
  # new way to make the parse pick a decoy PR or repo): a Bash merge names ONE
  # literal PR number or PR URL, in a command with no $, backtick or backslash,
  # so nothing expands and the quote mask is exact. Anything else blocks.
  if [ "$landing" = merge ]; then
    contract=""
    case "$rg_pr_ref" in
      https://github.com/*|github.com/*) printf '%s' "$rg_pr_ref" | grep -qE '^(https://)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$' || contract="the ref must be a PR number or PR URL" ;;
      ''|*[!0-9]*) contract="the ref must be a PR number or PR URL" ;;
    esac
    [ "$(printf '%s' "$raw" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge' | wc -l | tr -d ' ')" = 1 ] || contract="one merge per command"
    case "$cmd" in *'$'*|*'`'*|*\\*) contract="no \$, backtick or backslash in the command (put a long body in --body-file)" ;; esac
    if [ -n "$contract" ]; then
      echo "review-gate: merge with a literal PR number in a plain command — $contract." >&2
      exit 2
    fi
  fi

  # Which repo? Only the merge's own command may say: -R/--repo/--repo=, a
  # GH_REPO= prefix on that gh, or a PR URL that IS its ref. `export GH_REPO`
  # and a GH_REPO set anywhere else never count (fails closed).
  seg=""; judge_self=""; cd_doubt=""
  if [ "$landing" = merge ]; then
    seg="$(merge_segment "$raw" "$scan")"
    [ -n "$seg" ] || judge_self=1
    # Any doubt is this repo's: a quote, backslash or $'…' the mask could not
    # pair as bash does, or a GH_REPO set anywhere but as this gh's own prefix
    # (an export may point back at this repo from a sibling's directory).
    case "$scan" in *\"*|*\'*|*\\*) judge_self=1 ;; esac
    case "$cmd" in *"\$'"*) judge_self=1 ;; esac
    case "$raw" in *GH_REPO*) [ -n "$(seg_gh_repo "$seg")" ] || judge_self=1 ;; esac
  fi
  set -f
  # shellcheck disable=SC2086
  [ -n "$seg" ] && flag_repo="$(merge_repo_flag $seg)"
  set +f
  [ -n "$flag_repo" ] || [ -z "$seg" ] || flag_repo="$(seg_gh_repo "$seg")"
  if [ -z "$flag_repo" ]; then
    case "$rg_pr_ref" in
      https://github.com/*/*/pull/*|github.com/*/*/pull/*) flag_repo="$rg_pr_ref" ;;
    esac
  fi
  if [ -n "$judge_self" ]; then
    # A merge we cannot pin to one plain command, or a GH_REPO set anywhere
    # but on it: block, never guess a repo or a checkout (Vercel Security
    # Review, 2026-11-05).
    echo "review-gate: cannot tell which repo and checkout this \`gh pr merge\` runs in — run it alone, with -R if it is a sibling's." >&2
    exit 2
  elif [ -n "$flag_repo" ]; then
    # Only a plain [github.com/]owner/repo (or the PR URL) can name a sibling;
    # a masked or odd -R value is unknown, never a sibling.
    printf '%s' "$flag_repo" | grep -qE '^((https://)?github\.com/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/pull/[0-9]+)?$' \
      || { echo "review-gate: cannot read the -R/--repo of this \`gh pr merge\` exactly — give it as owner/repo." >&2; exit 2; }
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
      if [ -n "$cmd_cd" ] && [ -d "$cmd_cd" ]; then dir="$cmd_cd"; else cd_doubt=1; fi
      remaining="${BASH_REMATCH[3]}"
    done
    # A cd/git -C target we masked or cannot find blocks: neither the earlier
    # cwd (maybe a sibling) nor the project checkout (maybe another clone) is
    # known to be where this runs (Vercel Security Review, 2026-11-05).
    printf '%s' "$scan" | grep -qE 'git[[:space:]]+-C[[:space:]]+QMSG' && cd_doubt=1
    if [ -n "$cd_doubt" ]; then
      echo "review-gate: cannot read the directory this command runs in exactly — use a plain, existing path." >&2
      exit 2
    fi
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

if [ "$rg_ref_altered" = 1 ]; then
  echo "review-gate: cannot read the branch ref of this \`gh pr merge\` exactly — merge by PR number." >&2
  exit 2
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
