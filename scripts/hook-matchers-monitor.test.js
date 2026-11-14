// Claude Code 2.1.310 (the fleet's pinned version) fires a PreToolUse matcher
// "Bash" only for the Bash tool, never for a shell command started with the
// Monitor tool; "Bash|Monitor" fires for both. A gate on "Bash" alone let
// `git push` / `gh pr merge` through Monitor skip it (doxa-cns #2994).
// matcherSelects is the 2.1.310 rule, as in doxa-cns scripts/lib/hook-matchers.js;
// doxa-cns check-hook-drift.mjs applies the same rule to this repo daily.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function matcherSelects(matcher, tool) {
  if (matcher === undefined || matcher === null || matcher === '' || matcher === '*') return true;
  const m = String(matcher);
  if (/^[a-zA-Z0-9_|, -]+$/.test(m)) return m.split(/[|,]/).map((x) => x.trim()).filter(Boolean).includes(tool);
  try { return new RegExp(m).test(tool); } catch { return false; }
}
const bashOnly = (settings) => ((settings.hooks && settings.hooks.PreToolUse) || [])
  .filter((e) => matcherSelects(e.matcher, 'Bash') && !matcherSelects(e.matcher, 'Monitor'));

test('every PreToolUse hook that fires for Bash also fires for Monitor', () => {
  const settings = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '.claude', 'settings.json'), 'utf8'));
  assert.deepEqual(bashOnly(settings).map((e) => e.matcher), [], 'register shell-command hooks on "Bash|Monitor"');
  for (const g of ['kg-save-gate.sh', 'review-gate.sh', 'push-review-gate.sh', 'test-gate.sh']) {
    const on = settings.hooks.PreToolUse.some((e) => matcherSelects(e.matcher, 'Monitor') && (e.hooks || []).some((h) => String(h.command).split(/[\s"'/]+/).includes(g)));
    assert.ok(on, `${g} must fire for Monitor`);
  }
});

test('the rule catches a Bash-only matcher in list or regex form', () => {
  const reg = (matcher) => ({ hooks: { PreToolUse: [{ matcher, hooks: [] }] } });
  for (const m of ['Bash', 'Bash, Edit', '^Bash$', '(Bash)']) assert.equal(bashOnly(reg(m)).length, 1, m);
  for (const m of ['Bash|Monitor', 'Monitor|Bash', 'Bash, Monitor', '*', '', 'Edit|Write']) assert.equal(bashOnly(reg(m)).length, 0, m);
});
