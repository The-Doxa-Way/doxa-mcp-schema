# CLAUDE.md — doxa-mcp-schema

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

## What this is

The public side of Doxa MCP, a product of the Doxa business (doxa.app). The hosted server
(`https://doxa.app/mcp/v1`) lives in doxa-app. This repo holds the public tool schemas
(`schemas/`), the registry descriptor (`server.json`), the npm client `@thedoxaway/mcp-client`
(`clients/typescript/`), a local stdio server `@thedoxaway/mcp-server` (`server/`) that forwards
to the hosted endpoint, and the install docs.

The repo is PUBLIC. The hosted server code and the encourager prompt are private and stay in
doxa-app. Never copy them here, and never commit a secret.

The brand and voice rules live in doxa-brand (The-Doxa-Way/doxa-brand). Apply them; do not copy
them here.

## How to verify

There is no root `package.json`. Each package has its own `npm ci`.

- `clients/typescript`: `npm run build` (`tsc`) and `npm test`. The test is a live smoke test
  against `doxa.app/mcp/v1` on the free anon tier. A failure there can come from a change in the
  hosted server (doxa-app), not from this repo.
- `server`: `npm run build` (`tsc`). It has no tests. `npm run sync-tools` rewrites
  `server/src/tools.ts` from the live `tools/list`.
- Gate scripts: `node --test scripts/*.test.js scripts/*.test.mjs`.
- There is no lint script. CI does NOT run builds or tests. Run them yourself before you push.

## Gotchas

- Publishing is by hand, never by merge. Registry listing: bump `version` in `server.json`, then
  `mcp-publisher publish`, then deprecate the old version (`PUBLISHING.md`). npm: `npm publish`
  in the package folder. A version bump in git does not publish.
- The registry namespace is `io.github.The-Doxa-Way/doxa-mcp` (the org). The legacy
  `io.github.TheDoxaWay/doxa-mcp` belongs to the separate GitHub user `TheDoxaWay`.
- `npm pack` leaves `clients/typescript/*.tgz`. It is gitignored; never commit it.

## Landing

The production branch is `main`. Every change lands by branch, PR, independent review, merge.
Self-review never counts.

- Review: one `/code-review max` pass on the final diff on claude-opus-5-5, at most one fix
  round, then `ATTEST_REVIEW_LEVEL=max scripts/attest-review.sh "<verdict>"` before you push.
  `.github/workflows/claude-code-review.yml` runs only on manual dispatch.
- Hooks in `.claude/hooks/` enforce this: `push-review-gate.sh` (max review before `git push`),
  `review-gate.sh` (attestation before merge), `test-gate.sh` (a code change needs a test change,
  or `scripts/attest-review.sh "waived-tests: <reason>"`) and `kg-save-gate.sh`.
- kg-save: KG Guard CI fails a PR with no `.knowledge-graph/` change. Record it with
  `node scripts/knowledge-graph-merkle.js add "<Entity>" "<what and why>" <source-file> --type <Type>`
  and commit it in the same PR. Use `[skip-kg]` in the PR title only for a knowledge-free change.
- The org ruleset requires `gitleaks` (secret-scan). `kg-save-gate.sh` refuses `gh pr merge`
  while KG Guard is red or pending. Never merge over a red or pending check.
- An attestation is merge authority: the fleet auto-lander (openclaw `land-prs.mjs`) merges an
  attested, green PR.
- The gate hooks and `scripts/attest-review.sh` are rendered from The-Doxa-Way-CNS
  `fleet/gates/`. Fix the template there, never the copy here.

## Standing orders

Cross-repo rules, the standing orders and the fleet map live in The-Doxa-Way-CNS: its
`CLAUDE.md` and `docs/org-map.md`. The CNS CLAUDE.md is the authority. If this file and the CNS
disagree, the CNS wins.
