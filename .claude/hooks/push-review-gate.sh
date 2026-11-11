#!/usr/bin/env bash
#
# push-review-gate.sh — PreToolUse hook (Bash matcher): no `git push` of code
# that has no MAX-level review attestation.
#
# Garth's standing order (2026-11-11): "anything we build in loops or otherwise
# gets a max code review before we push — I want to reduce failed runs and
# reruns." review-gate.sh only checks at MERGE, after CI has already run (and
# failed) on unreviewed code. This gate moves the check to the PUSH: the
# commits a push would publish must be covered by an attestation from
# scripts/attest-review.sh run with ATTEST_REVIEW_LEVEL=max after ONE
# `/code-review max` pass + at most one fix round on the final diff. Max is the
# effort level of that one pass, never more rounds (CLAUDE.md § Model economy).
#
# WHAT IS CHECKED. The commits the push would publish are the commits of the
# pushed tip that are not yet on the DESTINATION branch, nor on the remote's
# integration or production branch (code already there was reviewed when it
# landed). A merge commit counts only for what its conflict resolution
# changed (`git show --remerge-diff`). A commit is EXEMPT (generated, no
# review needed) when every file it touches is KG
# state (.knowledge-graph-merkle.json, .knowledge-graph/) or matches this
# repo's generatedPaths — but a file matching authoredPaths (hand-written
# input inside a generated directory: doxa-cns vault/00-MOCs/, openclaw
# workspaces/*.py) is always code. A subject matching exemptSubjects
# (chore(sync)) exempts only non-code files: a script, workflow or .claude/
# file under that subject still needs review (a hand commit can spell any
# subject). Each other commit must be an ancestor of (or be) a
# new commit that holds a qualifying attestation in
# $GIT_COMMON_DIR/review-attest.jsonl:
#   - review_level "max" and a review verdict (not `waived-tests:`), or
#   - an explicit `waived:` verdict (the logged waiver; any level).
# A commit a review BLOCKED (review-blocked.jsonl, by SHA or tree) never
# qualifies. So a kg-save commit, or a merge of the base, after the attested
# commit still passes; a code commit after it does not. When that walk finds
# an uncovered commit, the portable content key (scripts/review-attest-check.mjs
# --require-level max, where the repo has it) is the last avenue: it passes a
# rebase of already-reviewed content.
#
# NOT GATED (exit 0): ref deletes (-d/--delete, `:ref`), tags (--tags, refs/tags/,
# a tag name), notes (refs/notes/ — attest-review.sh pushes its own note), a
# tip that is already on the remote, a push with only exempt commits.
# Docs-only or other no-code pushes need an explicit logged waiver:
#   scripts/attest-review.sh "waived: docs-only: <reason>"
# A push for HUMAN review that must NOT carry merge authority (an attestation
# is what land-prs.mjs merges on — KG AttestationIsMergeAuthority) uses the
# push-only waiver instead, logged here and nowhere else:
#   PUSH_GATE_WAIVE=<reason-token> git push …
#
# A command that COMMITS and then pushes (`git commit … && git push`) is judged
# before the commit exists, so the commit it will make is predicted from the
# dirty tree: when any staged, modified or untracked file is code (not KG /
# generated), the push blocks — commit, review, attest, then push alone. A
# refspec this hook cannot read (`"$BR"`) is judged as the checkout's HEAD.
#
# OTHER REPOS. A push into another checkout (`cd ../x && git push`,
# `git -C ../x push`) is judged by THAT repo's own copy of this gate, with its
# own exemptions and ledger, when the checkout carries one; else it passes.
#
# FAIL-OPEN (as the other gates): no payload, no jq, a command or ref this hook
# cannot read exactly (a cd to a variable path, an unknown remote, --all /
# --mirror, bash -c / eval), git errors — all allow. Only the confirmed case
# blocks: code commits with no qualifying attestation. Every block, every
# allow by exemption or waiver, and every push it could not judge
# ("unjudged") are logged to $GIT_COMMON_DIR/push-review-gate.jsonl, so the
# fail-open residue is measured, not invisible. The content-key checker is
# always this install's own copy, never the judged checkout's.
#
# Shell pushers that run without Claude (cns-push.js, social-*-record.mjs,
# git-commit-generated.js, heal-kg-conflict.mjs) are out of a Claude hook's
# reach by design: they publish generated state only, under
# scripts/lib/direct-push-gate.js or the commitGenerated allowlist, and every
# branch they push still meets review-gate.sh at merge.
#
# Rendered from doxa-cns fleet/gates/.claude/hooks/push-review-gate.sh.tmpl —
# fix the template, never a copy (check-hook-drift.mjs files the drift).
#
# Exit codes: 0 = allow, 2 = block (stderr shown to the model).

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
case "$cmd" in *push*) ;; *) exit 0 ;; esac

integration_branch='main'
prod_branch='main'
gen_re=''
authored_re=''
exempt_re=''
kg_re='^(\.knowledge-graph-merkle\.json|\.knowledge-graph/)'
# Files that run or govern: never exempt by a commit subject alone.
code_re='(\.(c|m)?js|\.ts|\.tsx|\.sh|\.py|\.ya?ml)$|^\.claude/|^\.github/|^bin/|^scripts/|(^|/)CLAUDE\.md$|(^|/)package(-lock)?\.json$'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
self_common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
self_origin="$(git -C "$here" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#/+$##')"
attest_cmd="$here/scripts/attest-review.sh"
# Diff/log output must not depend on the reader's git config.
GITQ=(-c core.quotePath=false -c diff.relative=false -c log.showRoot=true -c diff.renames=false)
hook_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
start_dir="${hook_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# gate_words <cmd>: every quoted string that holds whitespace becomes ONE token
# QMSG; plain quoted tokens lose their quotes; a "$(…)" keeps its inner command
# as its own segment. Same mask as review-gate.sh: message text is data and can
# never read as a push, a -C path or a refspec.
gate_words() {
  printf '%s' "$1" | perl -0777 -pe 's/((?<!\\)\x27[^\x27]*\x27|(?<!\\)"(?:[^"\\]|\\.)*")/ my $q = $1; my @s; if ($q =~ m{^"} && $q =~ m{\$\(|`}) { while ($q =~ m{\$(\((?:[^()]++|(?1))*\))|`([^`]*)`}g) { push @s, defined $1 ? substr($1, 1, -1) : $2 } @s ? join("", map { " ; $_ ; " } @s) : substr($q, 1, -1) } elsif ($q =~ m{^.[A-Za-z0-9_.\/:@+=,%-]+.$}) { substr($q, 1, -1) } else { "QMSG" } /ge' 2>/dev/null \
    || printf '%s' "$1" | tr -d "\"'"
}

# resolve_dir <base> <path>: an absolute directory, or empty when unknown.
resolve_dir() {
  local base="$1" p="$2"
  case "$p" in
    ''|*QMSG*|*'$'*|*'`'*) return 0 ;;
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    /*) : ;;
    *) [ -n "$base" ] || return 0; p="$base/$p" ;;
  esac
  [ -d "$p" ] && (cd "$p" 2>/dev/null && pwd)
}

log_decision() {   # log_decision <common> <decision> <sha> <ref> <detail>
  jq -n -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg d "$2" --arg sha "$3" --arg ref "$4" --arg detail "$5" \
    '{at:$at, decision:$d, sha:$sha, ref:$ref, detail:$detail}' >> "$1/push-review-gate.jsonl" 2>/dev/null || true
}

# exempt_filter: reads `git log --no-merges --format=%x1e%H%x1f%s --name-only`
# on stdin; prints the SHAs of the commits that are NOT exempt.
exempt_filter() {
  RS1="$(printf '\036')" US1="$(printf '\037')" CODE_RE="$code_re" GEN_RE="$gen_re" AUTH_RE="$authored_re" EXEMPT_RE="$exempt_re" KG_RE="$kg_re" awk '
    function flush() {
      if (sha == "") return
      if (code) print sha
      sha = ""; subj = ""; code = 0
    }
    substr($0, 1, 1) == ENVIRON["RS1"] {
      flush(); line = substr($0, 2); i = index(line, ENVIRON["US1"])
      sha = substr(line, 1, i - 1); subj = substr(line, i + 1); next
    }
    /^$/ { next }
    {
      if (ENVIRON["AUTH_RE"] != "" && $0 ~ ENVIRON["AUTH_RE"]) { code = 1; next }
      if ($0 ~ ENVIRON["KG_RE"]) next
      if (ENVIRON["GEN_RE"] != "" && $0 ~ ENVIRON["GEN_RE"]) next
      if (ENVIRON["EXEMPT_RE"] != "" && subj ~ ENVIRON["EXEMPT_RE"] && $0 !~ ENVIRON["CODE_RE"]) next
      code = 1
    }
    END { flush() }'
}

# qualifying_shas <common>: SHAs with a max-level review or an explicit waiver.
qualifying_shas() {
  local ledger="$1/review-attest.jsonl"
  [ -f "$ledger" ] || return 0
  jq -R -r 'fromjson? | select(type == "object" and (.sha | type) == "string" and (.verdict | type) == "string")
    | (.verdict | ascii_downcase) as $v
    | select(($v | startswith("waived-tests:")) | not)
    | select(($v | startswith("blocked:")) | not)
    | select(((.review_level // "") | tostring | ascii_downcase) == "max" or ($v | startswith("waived:")))
    | .sha' "$ledger" 2>/dev/null
}

# is_blocked <dir> <common> <sha>: a review BLOCKED this commit (by SHA or tree).
is_blocked() {
  local blocked="$2/review-blocked.jsonl" tree
  [ -f "$blocked" ] || return 1
  grep -qF "\"sha\":\"$3\"" "$blocked" && return 0
  tree="$(git -C "$1" rev-parse -q --verify "$3^{tree}" 2>/dev/null || true)"
  [ -n "$tree" ] && grep -qF "\"tree\":\"$tree\"" "$blocked"
}

# uncovered_commits <dir> <sha> <not-refs…>: code commits of <sha> not reachable
# from any <not-ref>. A non-merge commit by its own files; a merge commit by the
# files its conflict resolution changed (remerge-diff).
uncovered_commits() {
  local d="$1" sha="$2" m files; shift 2
  git -C "$d" "${GITQ[@]}" log --no-merges --no-renames --format='%x1e%H%x1f%s' --name-only "$sha" --not "$@" 2>/dev/null | exempt_filter
  for m in $(git -C "$d" rev-list --merges "$sha" --not "$@" 2>/dev/null); do
    files="$(git -C "$d" "${GITQ[@]}" show --remerge-diff --no-renames --format= --name-only "$m" 2>/dev/null)"
    [ -n "$files" ] || continue
    printf '\036%s\037merge resolution\n%s\n' "$m" "$files" | exempt_filter
  done
}

# check_sha <dir> <remote> <sha> <ref> <dst-branch>: 0 = covered, 2 = block.
check_sha() {
  local d="$1" remote="$2" sha="$3" ref="$4" dstb="$5" common new uncovered attested=() c result
  common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  # Code already on the destination, integration or production branch was
  # reviewed when it landed there.
  local nots=() b
  for b in "$dstb" "$integration_branch" "$prod_branch"; do
    [ -n "$b" ] && git -C "$d" rev-parse -q --verify "refs/remotes/$remote/$b" >/dev/null 2>&1 \
      && nots+=("refs/remotes/$remote/$b")
  done
  if [ "${#nots[@]}" -eq 0 ]; then
    log_decision "$common" unjudged "$sha" "$ref" "no remote branch to compare against"
    return 0
  fi
  new="$(git -C "$d" rev-list "$sha" --not "${nots[@]}" 2>/dev/null)" || return 0
  [ -n "$new" ] || return 0

  uncovered="$(uncovered_commits "$d" "$sha" "${nots[@]}")"
  if [ -z "$uncovered" ]; then
    log_decision "$common" allow-exempt "$sha" "$ref" "only merge, generated or KG commits"
    return 0
  fi

  # New commits that hold a qualifying attestation (and no block).
  local quals
  quals="$(qualifying_shas "$common" | sort -u)"
  if [ -n "$quals" ]; then
    for c in $new; do
      printf '%s\n' "$quals" | grep -qxF "$c" || continue
      is_blocked "$d" "$common" "$c" && continue
      attested+=("$c")
    done
  fi
  if [ "${#attested[@]}" -gt 0 ]; then
    uncovered="$(uncovered_commits "$d" "$sha" "${nots[@]}" "${attested[@]}")"
    [ -z "$uncovered" ] && return 0
  fi

  # Portable content key: a rebase or re-commit of content already reviewed at
  # max. Never for a tip a review BLOCKED; always THIS install's checker, never
  # the judged checkout's own copy.
  local checker="$here/scripts/review-attest-check.mjs"
  if ! is_blocked "$d" "$common" "$sha" && command -v node >/dev/null 2>&1 && [ -f "$checker" ] \
     && [ -n "$integration_branch" ] && git -C "$d" rev-parse -q --verify "refs/remotes/$remote/$integration_branch" >/dev/null 2>&1; then
    result="$(node "$checker" --cwd "$d" --base "$remote/$integration_branch" --head "$sha" --require-level max 2>/dev/null)" || result=""
    if [ -n "$result" ] && printf '%s' "$result" | jq -e '.reused == true and ((.reviewLevel // "") | ascii_downcase) == "max"' >/dev/null 2>&1; then
      return 0
    fi
  fi

  log_decision "$common" block "$sha" "$ref" "$(printf '%s\n' "$uncovered" | grep -c .) uncovered commit(s)"
  {
    echo "⛔ push-review-gate — '$ref' (${sha:0:8}) has code commits with no max-level review attestation:"
    printf '%s\n' "$uncovered" | head -10 | while IFS= read -r c; do
      [ -n "$c" ] && echo "    $(git -C "$d" log -1 --format='%h %s' "$c" 2>/dev/null)"
    done
    echo
    echo "Standing order (Garth 2026-11-11): ONE /code-review max pass on the final diff, at most one fix round, then attest and push:"
    echo "  /code-review max → fix round → ATTEST_REVIEW_LEVEL=max $attest_cmd \"clean\"   (or \"findings-fixed: <summary>\")"
    echo "No code (docs only)? Log an explicit waiver: $attest_cmd \"waived: docs-only: <reason>\""
    echo "Pushing only for HUMAN review (no merge authority wanted)? PUSH_GATE_WAIVE=<reason> git push …"
  } >&2
  return 2
}

# check_pending_commit <dir>: a `git commit` earlier in this command will add
# what is staged now, plus what its `git add` / `commit -a` would stage. 0 = only KG / generated files are dirty, 2 = block.
check_pending_commit() {
  local d="$1" files
  [ -n "$d" ] && [ -d "$d" ] || return 0
  files="$( {
      git -C "$d" diff --name-only --cached
      if [ "$add_all" = 1 ]; then
        git -C "$d" diff --name-only; git -C "$d" ls-files --others --exclude-standard
      elif [ "${#add_paths[@]}" -gt 0 ]; then
        git -C "$d" ls-files -m -o --exclude-standard -- "${add_paths[@]}"
      fi
      [ "$commit_all" = 1 ] && git -C "$d" diff --name-only
    } 2>/dev/null | sort -u)" || return 0
  [ -n "$files" ] || return 0
  if printf '\036%s\037pending\n%s\n' 0000000 "$files" | exempt_filter | grep -q .; then
    {
      echo "⛔ push-review-gate — this command commits and then pushes, so the new commit cannot have a review attestation yet."
      echo "Commit first, then ONE /code-review max on the final diff → ATTEST_REVIEW_LEVEL=max scripts/attest-review.sh \"clean\" → push as its own command."
    } >&2
    return 2
  fi
  return 0
}

# check_push <dir> <push args…>: 0 = allow, 2 = block.
check_push() {
  local d="$1"; shift
  if [ -z "$d" ] || [ ! -d "$d" ]; then
    log_decision "$self_common" unjudged "" "${*:-HEAD}" "cannot read the directory this push runs in"
    return 0
  fi
  local tcommon top other
  tcommon="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  local torigin
  torigin="$(git -C "$d" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#/+$##')"
  if [ "$tcommon" != "$self_common" ] && { [ -z "$self_origin" ] || [ "$torigin" != "$self_origin" ]; }; then
    # Another repo: its own copy of this gate decides (once — no recursion).
    [ -z "${PUSH_REVIEW_GATE_DELEGATED:-}" ] || return 0
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 0
    other="$top/.claude/hooks/push-review-gate.sh"
    [ -f "$other" ] || return 0
    jq -n -c --arg c "git push $*" --arg cwd "$top" '{tool_input:{command:$c}, cwd:$cwd}' \
      | PUSH_REVIEW_GATE_DELEGATED=1 CLAUDE_PROJECT_DIR="$top" bash "$other"
    [ $? -eq 2 ] && return 2
    return 0
  fi

  local remote="" refspecs=() tags=0 a args=()
  for a in "$@"; do
    case "$a" in [0-9]'>'*|'>'*|'<'*) continue ;; esac
    a="${a%%[<>]*}"
    [ -n "$a" ] && args+=("$a")
  done
  set -- ${args[@]+"${args[@]}"}
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -d|--delete) return 0 ;;
      --all|--branches|--mirror) log_decision "$tcommon" unjudged "" "$1" "many refs at once"; return 0 ;;
      --tags) tags=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) [ "$1" = --repo ] && [ $# -gt 1 ] && remote="$2"; shift ;;
      --repo=*) remote="${1#--repo=}" ;;
      QMSG|*'$'*) if [ -z "$remote" ]; then remote=QMSG; else refspecs+=(HEAD); fi ;;   # unreadable: judge HEAD
      -*) ;;
      *) if [ -z "$remote" ]; then remote="$1"; else refspecs+=("$1"); fi ;;
    esac
    shift
  done
  for a in "$@"; do
    case "$a" in QMSG|*'$'*) [ -n "$remote" ] && { refspecs+=(HEAD); continue; } ;; esac
    if [ -z "$remote" ]; then remote="$a"; else refspecs+=("$a"); fi
  done
  if [ "${#refspecs[@]}" -eq 0 ]; then
    [ "$tags" = 1 ] && return 0
    refspecs=(HEAD)
  fi
  if [ -z "$remote" ]; then
    local cur
    cur="$(git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null)"
    [ -n "$cur" ] && remote="$(git -C "$d" config "branch.$cur.remote" 2>/dev/null)"
    [ -n "$remote" ] || remote=origin
  fi
  # Only a configured remote name with remote-tracking refs can be judged.
  if ! printf '%s' "$remote" | grep -qE '^[A-Za-z0-9_.-]+$' || ! git -C "$d" remote get-url "$remote" >/dev/null 2>&1; then
    log_decision "$tcommon" unjudged "" "$remote" "remote is not a configured remote name"
    return 0
  fi
  [ -n "$(git -C "$d" for-each-ref --count=1 --format='%(refname)' "refs/remotes/$remote/" 2>/dev/null)" ] || return 0

  local rc=0 rs src dst sha dstb cur
  cur="$(git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null)"
  for rs in "${refspecs[@]}"; do
    rs="${rs#+}"
    [ "$rs" = ':' ] && rs=HEAD                       # a "matching" push: judge HEAD at least
    src="${rs%%:*}"; dst=""
    case "$rs" in *:*) dst="${rs#*:}" ;; esac
    [ -n "$src" ] || continue                        # :dst deletes a ref
    case "$src" in refs/notes/*) continue ;; esac
    # Decided by destination: a tag or notes destination publishes no branch;
    # a tag source with no destination is a tag push. A tag sent to a branch is judged.
    case "$dst" in refs/tags/*|refs/notes/*) continue ;; esac
    if [ -z "$dst" ]; then
      case "$src" in refs/tags/*) continue ;; esac
      if ! git -C "$d" show-ref -q --verify "refs/heads/$src" 2>/dev/null \
         && git -C "$d" show-ref -q --verify "refs/tags/$src" 2>/dev/null; then
        continue                                     # a tag name
      fi
    fi
    if ! sha="$(git -C "$d" rev-parse -q --verify "$src^{commit}" 2>/dev/null)"; then
      log_decision "$tcommon" unjudged "" "$src" "refspec does not resolve to a commit"
      continue
    fi
    dstb="${dst#refs/heads/}"
    if [ -z "$dstb" ]; then
      case "$src" in HEAD|@) dstb="$cur" ;; refs/heads/*) dstb="${src#refs/heads/}" ;; *) dstb="$src" ;; esac
    fi
    check_sha "$d" "$remote" "$sha" "$src" "$dstb" || rc=2
  done
  return $rc
}

# Walk the command clause by clause: `cd` moves the directory, `git … push`
# is judged where it runs (its own -C wins).
status=0
dir="$start_dir"
committed_dirs=""
add_all=0
commit_all=0
add_paths=()
clauses="$(gate_words "$cmd" | tr ';&|()\n' '\n\n\n\n\n\n')"
while IFS= read -r clause; do
  set -f
  # shellcheck disable=SC2086
  set -- $clause
  set +f
  waive=""
  while [ $# -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    case "$1" in PUSH_GATE_WAIVE=?*) waive="${1#PUSH_GATE_WAIVE=}" ;; esac
    shift
  done
  # Shell keywords and plain wrappers in front of the command.
  while [ $# -gt 0 ]; do
    case "$1" in
      if|then|do|else|elif|while|until|'!'|'{'|time|command|nohup|exec|env) shift ;;
      timeout|gtimeout) shift; [ $# -gt 0 ] && shift ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || continue
  case "$1" in
    cd) dir="$(resolve_dir "$dir" "${2:-$HOME}")"; continue ;;
    git|*/git) shift ;;
    *) continue ;;
  esac
  gdir="$dir"
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) gdir="$(resolve_dir "$gdir" "${2:-}")"; shift; [ $# -gt 0 ] && shift ;;
      -c) shift; [ $# -gt 0 ] && shift ;;
      --git-dir|--work-tree|--namespace) gdir=""; shift; [ $# -gt 0 ] && shift ;;
      --git-dir=*|--work-tree=*) gdir=""; shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  case "${1:-}" in
    add)
      shift
      for a in "$@"; do
        case "$a" in -A|--all|.|./|:/|-u|--update) add_all=1 ;; QMSG|*'$'*|*'*'*) add_all=1 ;; -*) ;; *) add_paths+=("$a") ;; esac
      done
      continue ;;
    commit)
      # A commit made earlier in THIS command does not exist yet when the hook runs.
      for a in "$@"; do { [ "$a" = --all ] || [[ "$a" =~ ^-[A-Za-z]*a[A-Za-z]*$ ]]; } && commit_all=1; done
      committed_dirs="$committed_dirs${gdir:-?}
"
      continue ;;
    merge|cherry-pick|revert|am|pull|rebase) continue ;;
    push) ;;
    *) continue ;;
  esac
  shift
  if [ -n "$waive" ]; then
    wcommon="$(git -C "${gdir:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      && log_decision "$wcommon" waived-push "$(git -C "$gdir" rev-parse -q --verify HEAD 2>/dev/null)" "${*:-HEAD}" "PUSH_GATE_WAIVE=$waive"
    continue
  fi
  if [ -n "$committed_dirs" ] && printf '%s' "$committed_dirs" | grep -qxF -e "${gdir:-?}" -e '?'; then
    check_pending_commit "$gdir" || { status=2; continue; }
  fi
  check_push "$gdir" "$@" || status=2
done <<EOF
$clauses
EOF
exit "$status"
