#!/usr/bin/env bash
#
# push-review-gate.sh — PreToolUse hook (Bash|Monitor matcher): no `git push` of code
# that has no review attestation at the diff's risk tier (REVIEW TIER below).
#
# Garth's standing order (2026-11-11): "anything we build in loops or otherwise
# gets a max code review before we push — I want to reduce failed runs and
# reruns." Tiered 2026-11-14 ("we need to dial this in"): prose docs, tests and
# listed data folders need a lower level; every other path stays max (REVIEW
# TIER below; evals/factory/README.md Experiment 1 has the numbers).
# review-gate.sh only checks at MERGE, after CI has already run (and
# failed) on unreviewed code. This gate moves the check to the PUSH: the
# commits a push would publish must be covered by an attestation from
# scripts/attest-review.sh run with ATTEST_REVIEW_LEVEL=<tier> after ONE
# `/code-review <tier>` pass + at most one fix round on the final diff. The
# level is the effort of that one pass, never more rounds (CLAUDE.md § Model
# economy).
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
#   - a review_level at the tier or higher and a review verdict (not
#     `waived-tests:`), or
#   - an explicit `waived:` verdict (the logged waiver) while the tier is
#     medium or low; a max-tier diff cannot be waived here.
# A commit a review BLOCKED (review-blocked.jsonl, by SHA or tree) never
# qualifies. So a kg-save commit, or a merge of the base, after the attested
# commit still passes; a code commit after it does not.
#
# NOT GATED (exit 0): ref deletes (-d/--delete, `:ref`), tags (--tags, refs/tags/,
# a tag name), notes (refs/notes/ — attest-review.sh pushes its own note), a
# tip that is already on the remote, a push with only exempt commits.
# Docs-only or data-only pushes (tier low or medium) may use an explicit logged waiver:
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
# fail-open residue is measured, not invisible.
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

integration_branch='main'
prod_branch='main'
gen_re=''
authored_re=''
exempt_re=''
kg_re='^(\.knowledge-graph-merkle\.json|\.knowledge-graph/)'
# Files that run or govern: never exempt by a commit subject alone.
code_re='(\.(c|m)?js|\.ts|\.tsx|\.sh|\.py|\.ya?ml)$|^\.claude/|^\.github/|^bin/|^scripts/|^fleet/|^config/|\.tmpl$|\.sql$|(^|/)(CLAUDE|AGENTS|SKILL)\.md$|(^|/)package(-lock)?\.json$'

# REVIEW TIER (Garth 2026-11-14, "dial in" the max review; evals/factory
# Experiment 1; two max modes 2026-11-15, Experiment 4). The level the ONE
# pre-push review must run at comes from the changed paths alone (zero LLM),
# not from the author. It is an ALLOWLIST: only the tested low-risk shapes get
# a lower level (the gate fails CLOSED, never open to a lower level):
#   low     prose docs: .md/.mdx under docs/, specs/, handoffs/, proposals/,
#           evals/ or goals/, and README.md / CHANGELOG.md anywhere.
#   medium  tests (*.test.*, *.spec.*, __tests__/, test/, tests/, test_*.py),
#           and data files (.json, .jsonl, .csv, .tsv, .yaml, .yml) under
#           goals/_reports/, evals/, handoffs/, proposals/, scripts/data/,
#           fixtures/ or results/ (a repo's maxTierPaths take a path back to
#           max, e.g. shipped Scripture text in scripture-grounding-mcp).
#   max     ONE opus-reviewer pass at max effort, no finder fan-out: every
#           other path (instruction and canon files, config, product and app
#           code, scripts, manifests, tier_max_re, maxTierPaths).
#   max-fanout  the full `/code-review max` finder fan-out, ONLY for the
#           critical set: a path in tier_fanout_re (the gate, hook, review and
#           CI machinery, fleet gate config, SQL, migrations and schema) or a
#           non-doc path that names money (payments, purchases, entitlement,
#           pricing, paywall), auth or credentials, RLS/policy, security,
#           user data, the encourager or its safety guards, or outbound sends
#           (tier_kw_re), even inside a low or medium folder. A path that
#           cannot be read (no path, a C-quoted name: git quotes a name with
#           ", \ or a control byte) or any error is max-fanout.
# The diff's tier is its highest file. KG state and generated paths do not
# count (they are exempt above). "high" is a valid review level (it meets a
# low or medium tier) but no path tiers high: Experiment 1 tested only medium
# against max. scripts/push-review-gate.test.mjs pins this.
tier_max_re='^\.github/|^\.claude/|^agent-home/|^fleet/|^config/|^agents/|^learnings/|^ontology/|^authority/|^vault/00-MOCs/|(^|/)(CLAUDE|AGENTS|SKILL)\.md$|(^|/)skills/|(^|/)PROMPT[^/]*\.md$|-tick-prompt\.md$|^goals/[^/]+/GOAL\.md$|^goals/convert/experiments/|^docs/cns-reference\.md$|^docs/landing/|^evals/[^/]+/(rubric|judge|grader)|\.sql$'
tier_fanout_re='^\.github/|^\.claude/hooks/|^agent-home/hooks/|(^|/)\.githooks/|(^|/)\.husky/|(^|/)user-hooks[^/]*$|(^|/)\.?gitleaks[^/]*$|^\.claude/settings[^/]*\.json$|^\.claude/agents/opus-reviewer\.md$|^\.claude/commands/(merge-to-main|merge-to-staging|recursive-quality-gate)\.md$|^fleet/gates/|^config/fleet\.ya?ml$|(^|/)protected-paths\.ya?ml$|(^|/)(attest-review|review-attest|review-preflight|land-prs|check-kg-merge-integrity)[^/]*$|^\.claude/agents/[^/]*review[^/]*\.md$|^\.claude/commands/[^/]*review[^/]*\.md$|^goals/convert/experiments/|^learnings/policy\.ya?ml$|^goals/evidence-policy\.ya?ml$|^scripts/(lib/)?(loop-ledger|evidence-contract|evidence-verify|experiment-contract|goal-grader|experiment-grader|experiment-validate|cns-push-mode|cns-push)\.[cm]?js$|^scripts/cron/cns-push\.js$|\.sql$|(^|/)migrations?/|(^|/)schema[^/]*\.(sql|prisma)$'
tier_kw_re='(^|[/_.-])gates?([/_.-]|$)|paywall|premium|entitle|stripe|revenuecat|(^|[^a-z])iap([^a-z]|$)|receipt|storekit|play-?billing|server-notifications|play-notifications|portal-session|pricing|billing|subscri|checkout|purchase|payment|invoice|auth([^o]|o[^r]|$)|authori[sz]|login|passw|secret|credential|keychain|token|jwt|api-?key|mcp-key|(^|[^a-z])rls([^a-z]|$)|polic|permission|secur|crypt|signing|signature|encourag|safety|moderat|crisis|age-?gate|consent|privacy|gdpr|outbound|send-mode|email|mailer|outreach|nurture|user[-_]?data|personal[-_]?data|(^|[^a-z])pii|delete[-_]?account|account[-_]?deletion|data[-_]?export|export[-_]?(data|account)|(^|/)config\.toml$'
tier_extra_max_re=''
# A repo's own critical set (config/fleet.yaml gates.fanoutPaths): paths the
# generic lists miss that must get the fan-out too (doxa-app: push and outbound
# sends, user data, encourager safety, store and release machinery). It joins
# tier_fanout_re, so an exempt subject never exempts these paths either.
tier_extra_fanout_re=''
[ -n "$tier_extra_fanout_re" ] && tier_fanout_re="$tier_fanout_re|$tier_extra_fanout_re"
tier_doc_re='^(docs|specs|handoffs|proposals|evals|goals)/.*\.mdx?$|(^|/)(README|CHANGELOG)\.md$'
tier_medium_re='\.(test|spec)\.[cm]?[jt]sx?$|(^|/)(__tests__|tests?)/|(^|/)test_[^/]+\.py$|^(goals/_reports|evals|handoffs|proposals|scripts/data)/.*\.(json|jsonl|csv|tsv|ya?ml)$|(^|/)(fixtures|results)/.*\.(json|jsonl|csv|tsv|ya?ml)$'

# level_rank <level>: low 1 … max 5, max-fanout 6; anything else 0.
level_rank() {
  case "$1" in low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; xhigh) echo 4 ;; max) echo 5 ;; max-fanout) echo 6 ;; *) echo 0 ;; esac
}

# review_tier: reads changed paths on stdin; prints low|medium|high|max|max-fanout.
# KG state and generated paths (not authored ones) are skipped; only such
# paths = low (nothing to review). No path at all = max-fanout.
review_tier() {
  FAN_RE="$tier_fanout_re" MAX_RE="$tier_max_re" XMAX_RE="$tier_extra_max_re" KW_RE="$tier_kw_re" DOC_RE="$tier_doc_re" MED_RE="$tier_medium_re" \
  GEN_RE="$gen_re" AUTH_RE="$authored_re" KG_RE="$kg_re" awk '
    function rank(t) { return t == "max-fanout" ? 6 : t == "max" ? 5 : t == "high" ? 3 : t == "medium" ? 2 : t == "low" ? 1 : 0 }
    /^$/ { next }
    /^"/ { n++; best = "max-fanout"; next }
    {
      p = $0; sub(/^\.\//, "", p)
      authored = (ENVIRON["AUTH_RE"] != "" && p ~ ENVIRON["AUTH_RE"])
      if (!authored && p ~ ENVIRON["KG_RE"]) { k++; next }
      if (!authored && ENVIRON["GEN_RE"] != "" && p ~ ENVIRON["GEN_RE"]) { k++; next }
      n++
      doc = (p ~ ENVIRON["DOC_RE"])
      # camelCase names keep their word boundaries (GraceRecordRLS, useIAP, stripPII):
      # the keywords also see the name with a _ at each lower-to-upper step and
      # before the last capital of an acronym that starts a word (IAPService).
      w = p; while (match(w, /[a-z0-9][A-Z]|[A-Z][A-Z][a-z]/)) w = substr(w, 1, RSTART) "_" substr(w, RSTART + 1)
      if (p ~ ENVIRON["FAN_RE"] || (!doc && (tolower(p) ~ ENVIRON["KW_RE"] || tolower(w) ~ ENVIRON["KW_RE"] || p ~ /[a-z]Gates?([A-Z._-]|$)/))) t = "max-fanout"
      else if (p ~ ENVIRON["MAX_RE"] || (ENVIRON["XMAX_RE"] != "" && p ~ ENVIRON["XMAX_RE"])) t = "max"
      else if (doc) t = "low"
      else if (p ~ ENVIRON["MED_RE"]) t = "medium"
      else t = "max"
      if (rank(t) > rank(best)) best = t
    }
    END { print (n > 0 && best != "") ? best : (n == 0 && k > 0) ? "low" : "max-fanout" }'
}


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
  RS1="$(printf '\036')" US1="$(printf '\037')" CODE_RE="$code_re" FAN_RE="$tier_fanout_re" GEN_RE="$gen_re" AUTH_RE="$authored_re" EXEMPT_RE="$exempt_re" KG_RE="$kg_re" awk '
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
      if (ENVIRON["EXEMPT_RE"] != "" && subj ~ ENVIRON["EXEMPT_RE"] && $0 !~ ENVIRON["CODE_RE"] && $0 !~ ENVIRON["FAN_RE"]) next
      code = 1
    }
    END { flush() }'
}

# qualifying_shas <common> <need-rank>: SHAs with a review at the tier's level
# or higher, or an explicit `waived:` row — the waiver only while the tier is
# medium or lower (rank <= 2): a max-tier diff needs a real review.
qualifying_shas() {
  local ledger="$1/review-attest.jsonl"
  [ -f "$ledger" ] || return 0
  jq -R -r --argjson need "${2:-6}" 'fromjson? | select(type == "object" and (.sha | type) == "string" and (.verdict | type) == "string")
    | (.verdict | ascii_downcase) as $v
    | ({"low":1,"medium":2,"high":3,"xhigh":4,"max":5,"max-fanout":6}[(.review_level // "") | tostring | ascii_downcase] // 0) as $r
    | select(($v | startswith("waived-tests:")) | not)
    | select(($v | startswith("blocked:")) | not)
    | ($v | startswith("waived:")) as $w
    | select(($w and $need <= 2) or (($w | not) and $r >= $need))
    | .sha' "$ledger" 2>/dev/null
}

# commit_files <dir> <sha…>: the files each commit changed (a merge: what its
# conflict resolution changed), one per line.
commit_files() {
  local d="$1" c; shift
  for c in "$@"; do
    if [ -n "$(git -C "$d" rev-list --no-walk --min-parents=3 "$c" 2>/dev/null)" ]; then
      # An octopus merge has no remerge-diff (git prints a warning line in its
      # place): judge everything it brings in over its first parent.
      git -C "$d" "${GITQ[@]}" diff --no-renames --name-only "$c^1" "$c" 2>/dev/null
    elif [ -n "$(git -C "$d" rev-list --no-walk --merges "$c" 2>/dev/null)" ]; then
      git -C "$d" "${GITQ[@]}" show --remerge-diff --no-renames --format= --name-only "$c" 2>/dev/null
    else
      git -C "$d" "${GITQ[@]}" show --no-renames --format= --name-only "$c" 2>/dev/null
    fi
  done
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

# cover_rounds: with d, sha, common, new, nots[] and uncovered set by the
# caller (bash locals are dynamic), applies the attestations in rounds and
# sets tier, need, attested[] and uncovered. Returns 0 when nothing is left
# uncovered. Each round: the attestations at the tier or higher cover their
# ancestors, then the tier is computed again over the commits still
# uncovered, so a docs commit after a max-reviewed code commit needs only its
# own (low) level. Sound: a lower level is only ever asked for once every
# commit at a higher tier is covered.
cover_rounds() {
  local prev=7 quals added c
  while :; do
    # shellcheck disable=SC2086
    tier="$(commit_files "$d" $uncovered | review_tier)"
    need="$(level_rank "$tier")"
    [ "$need" -gt 0 ] || { tier=max-fanout; need=6; }
    [ "$need" -lt "$prev" ] || return 1
    prev="$need"
    # New commits that hold a qualifying attestation (and no block).
    quals="$(qualifying_shas "$common" "$need" | sort -u)"
    added=0
    if [ -n "$quals" ]; then
      for c in $new; do
        printf '%s\n' "$quals" | grep -qxF "$c" || continue
        printf ' %s ' "${attested[*]:-}" | grep -qF " $c " && continue
        is_blocked "$d" "$common" "$c" && continue
        attested+=("$c")
        added=1
      done
    fi
    [ "$added" -eq 1 ] || return 1
    uncovered="$(uncovered_commits "$d" "$sha" "${nots[@]}" "${attested[@]}")"
    [ -z "$uncovered" ] && return 0
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

  # The review level this push needs: the tier of what the uncovered commits
  # change (max when it cannot be read). Coverage is applied in rounds: the
  # attestations at the tier or higher cover their ancestors, then the tier is
  # computed again over the commits still uncovered, so a docs commit after a
  # max-reviewed code commit needs only its own (low) level. Sound because each
  # round only lowers the level for commits whose own files are at that tier.
  local tier need
  cover_rounds && return 0

  log_decision "$common" block "$sha" "$ref" "$(printf '%s\n' "$uncovered" | grep -c .) uncovered commit(s); tier $tier"
  {
    echo "⛔ push-review-gate — '$ref' (${sha:0:8}) has code commits with no review attestation at level $tier or higher (the diff's risk tier):"
    printf '%s\n' "$uncovered" | head -10 | while IFS= read -r c; do
      [ -n "$c" ] && echo "    $(git -C "$d" log -1 --format='%h %s' "$c" 2>/dev/null)"
    done
    echo
    echo "Standing order (Garth 2026-11-11, tiered 2026-11-14, two max modes 2026-11-15): ONE review pass at the diff's tier on the final diff, at most one fix round, then attest and push:"
    case "$tier" in
      max-fanout) echo "  /code-review max (the finder fan-out: this diff touches a critical path) → fix round → ATTEST_REVIEW_LEVEL=max-fanout $attest_cmd \"clean\"   (or \"findings-fixed: <summary>\")" ;;
      max) echo "  ONE opus-reviewer Agent pass (its effort is max; prompt starts \"review-mode max <worktree>\"), no /code-review fan-out → fix round → ATTEST_REVIEW_LEVEL=max $attest_cmd \"clean\"   (or \"findings-fixed: <summary>\")" ;;
      *) echo "  /code-review $tier → fix round → ATTEST_REVIEW_LEVEL=$tier $attest_cmd \"clean\"   (or \"findings-fixed: <summary>\")" ;;
    esac
    if [ "$need" -le 2 ]; then
      echo "No code (docs or data only)? Log an explicit waiver: $attest_cmd \"waived: docs-only: <reason>\""
    fi
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
      git -C "$d" "${GITQ[@]}" diff --name-only --cached
      if [ "$add_all" = 1 ]; then
        git -C "$d" "${GITQ[@]}" diff --name-only; git -C "$d" "${GITQ[@]}" ls-files --others --exclude-standard --full-name -- ':/'
      elif [ "${#add_paths[@]}" -gt 0 ]; then
        git -C "$d" "${GITQ[@]}" ls-files -m -o --exclude-standard --full-name -- "${add_paths[@]}"
      fi
      [ "$commit_all" = 1 ] && git -C "$d" "${GITQ[@]}" diff --name-only
    } 2>/dev/null | sort -u)" || return 0
  [ -n "$files" ] || return 0
  if printf '\036%s\037pending\n%s\n' 0000000 "$files" | exempt_filter | grep -q .; then
    {
      echo "⛔ push-review-gate — this command commits and then pushes, so the new commit cannot have a review attestation yet."
      echo "Commit first, then ONE review at the tier on the final diff (tier: bash .claude/hooks/push-review-gate.sh --tier; max = one opus-reviewer pass, max-fanout = /code-review max) → ATTEST_REVIEW_LEVEL=<tier> scripts/attest-review.sh \"clean\" → push as its own command."
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
# Diff/log output must not depend on the reader's git config.
GITQ=(-c core.quotePath=false -c diff.relative=false -c log.showRoot=true -c diff.renames=false)

# `push-review-gate.sh --tier [<base-ref>]` (in a checkout): prints the level
# the pre-push review of HEAD must run at: the tier of the commits not yet on
# origin/<integration|prod> (or <base-ref>) and not yet covered by an
# attestation, by the same rounds the gate applies, and of any uncommitted or
# untracked file (the higher wins; `--committed` leaves those out, for
# attest-review.sh). Nothing left to review: low. Any error: max-fanout. `--tier-paths`: the tier of the paths read on stdin.
# Loops call this to pick the /code-review level; attest-review.sh calls it to
# refuse a level below it (or a waiver above medium); the gate enforces it.
if [ "${1:-}" = --tier ] || [ "${1:-}" = --tier-paths ]; then
  if [ "$1" = --tier-paths ]; then review_tier; exit 0; fi
  d="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo max-fanout; exit 0; }
  common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo max-fanout; exit 0; }
  sha="$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null)" || { echo max-fanout; exit 0; }
  nots=() base="" committed=0
  for a in "${@:2}"; do
    case "$a" in --committed) committed=1 ;; *) base="$a" ;; esac
  done
  if [ -n "$base" ]; then
    git -C "$d" rev-parse -q --verify "$base" >/dev/null 2>&1 || { echo max-fanout; exit 0; }
    nots+=("$base")
  else
    for b in "$integration_branch" "$prod_branch"; do
      [ -n "$b" ] && git -C "$d" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && nots+=("refs/remotes/origin/$b")
    done
  fi
  [ "${#nots[@]}" -gt 0 ] || { echo max-fanout; exit 0; }
  # Work not committed yet counts too: a loop may ask before it commits.
  dirty="$( { git -C "$d" "${GITQ[@]}" diff --name-only HEAD && git -C "$d" "${GITQ[@]}" ls-files --others --exclude-standard; } 2>/dev/null)" || { echo max-fanout; exit 0; }
  t_dirty=""
  [ -n "$dirty" ] && [ "$committed" -eq 0 ] && t_dirty="$(printf '%s\n' "$dirty" | review_tier)"
  t_commits=low
  new="$(git -C "$d" rev-list "$sha" --not "${nots[@]}" 2>/dev/null)" || { echo max-fanout; exit 0; }
  if [ -n "$new" ]; then
    uncovered="$(uncovered_commits "$d" "$sha" "${nots[@]}")"
    attested=()
    if [ -n "$uncovered" ] && ! cover_rounds; then t_commits="${tier:-max-fanout}"; fi
  fi
  if [ -n "$t_dirty" ] && [ "$(level_rank "$t_dirty")" -gt "$(level_rank "$t_commits")" ]; then echo "$t_dirty"; else echo "$t_commits"; fi
  exit 0
fi

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
case "$cmd" in *push*) ;; *) exit 0 ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
self_common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
self_origin="$(git -C "$here" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#/+$##')"
attest_cmd="$here/scripts/attest-review.sh"
hook_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
start_dir="${hook_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

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
