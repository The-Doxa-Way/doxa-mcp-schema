/**
 * ontology-guard.js — reject off-ontology entity types AT WRITE TIME.
 *
 * WHY (Garth 2026-08-02, "make sure across all repos the kg discipline is up
 * to scratch"): nothing validated entityType on the way in. kg-audit-all.js
 * reports drift afterwards, but a report nobody is blocked by is a report
 * nobody acts on — 80 off-ontology entities had accumulated across the four
 * repos, the largest class being a literal `Unknown`. I added two of them
 * myself the same evening, while writing the doctrine telling others not to.
 *
 * A gate that only reports is how drift becomes normal. This one refuses the
 * write and names the closest legal type, so the correct thing is also the
 * fastest thing.
 *
 * FAIL-OPEN on a missing ontology, deliberately: a session in a checkout with
 * no doxa-cns beside it must still be able to kg-save (the kg-save gate blocks
 * landings without one). It warns loudly instead — an unreadable ontology is a
 * check outage, not a licence to invent types.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// When DOXA_ONTOLOGY_PATH is set it is AUTHORITATIVE — no fallback to the
// discovered paths. Explicit config falling back silently would mean a typo'd
// path validates against whichever ontology happens to be lying around; it is
// also what makes the fail-open branch actually reachable in tests.
const ONTOLOGY_PATHS = process.env.DOXA_ONTOLOGY_PATH
  ? [process.env.DOXA_ONTOLOGY_PATH]
  : [
      path.join(__dirname, '..', '..', 'ontology', 'entity-types.yaml'),
      path.join(os.homedir(), 'Documents/Projects/doxa-cns/ontology/entity-types.yaml'),
    ];

/**
 * Minimal YAML reader for this one file's shape (`kinds:` mapping and
 * `aliases:` mapping). Deliberately dependency-free: this runs inside every
 * repo's kg writer, and requiring js-yaml in four repos to read two mappings
 * is a worse trade than thirty lines here.
 */
function parseEntityTypes(text) {
  const kinds = new Set();
  const aliases = new Map();
  let section = null;
  // A kind's own children (description, subtypes, statuses) are indented
  // deeper than the kind itself. Without pinning to the FIRST indent seen in
  // the section, those children get collected as if they were kinds — which
  // is how "description, statuses, subtypes" ended up being offered as valid
  // entity types in the rejection message.
  let sectionIndent = null;
  for (const raw of String(text).split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (!line || /^\s*#/.test(line)) continue;
    if (/^[A-Za-z_]+:/.test(line)) {
      section = line.split(':')[0];
      sectionIndent = null;
      continue;
    }
    // Keys may contain spaces or hyphens ("Analysis Report", "test-suite") and
    // may be quoted, so capture everything up to the first colon rather than a
    // narrow identifier class. Eight real aliases were being dropped by an
    // [A-Za-z0-9_]+ pattern, and a dropped alias means a legitimate type gets
    // wrongly rejected at write time.
    const m = line.match(/^(\s+)(.+?)\s*:(.*)$/);
    if (!m) continue;
    const [, indent, rawKey, rest] = m;
    const key = rawKey.trim().replace(/^["']|["']$/g, '');
    if (!key || key.startsWith('-')) continue; // list item, not a mapping key
    if (sectionIndent === null) sectionIndent = indent.length;
    if (indent.length !== sectionIndent) continue; // a child of the entry above
    if (section === 'kinds') kinds.add(key);
    else if (section === 'aliases') {
      const target = rest.trim().replace(/^["']|["']$/g, '');
      if (target) aliases.set(key, target);
    }
  }
  return { kinds, aliases };
}

let _cache = null;

/** Load the ontology, or null when it genuinely cannot be read. */
function loadOntology() {
  if (_cache !== null) return _cache;
  for (const p of ONTOLOGY_PATHS) {
    try {
      const parsed = parseEntityTypes(fs.readFileSync(p, 'utf8'));
      if (parsed.kinds.size > 0) {
        _cache = parsed;
        return _cache;
      }
    } catch {
      /* try the next candidate */
    }
  }
  _cache = null;
  return null;
}

/** Levenshtein, small and local — used only to suggest a near-miss type. */
function distance(a, b) {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j += 1) dp[0][j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      dp[i][j] = Math.min(
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + (a[i - 1].toLowerCase() === b[j - 1].toLowerCase() ? 0 : 1),
      );
    }
  }
  return dp[a.length][b.length];
}

function suggest(type, kinds) {
  let best = null;
  let bestD = Infinity;
  for (const k of kinds) {
    const d = distance(type, k);
    if (d < bestD) {
      bestD = d;
      best = k;
    }
  }
  // Only offer a suggestion when it is plausibly a typo, not a random nearest.
  return bestD <= Math.max(3, Math.floor(type.length / 2)) ? best : null;
}

/**
 * Check one entity type.
 * Returns { ok: true, type } with aliases already resolved, or
 * { ok: false, message } describing exactly what to do instead.
 */
function checkEntityType(entityType) {
  const ontology = loadOntology();
  if (!ontology) {
    return {
      ok: true,
      type: entityType,
      warning:
        'ontology not readable (looked for doxa-cns/ontology/entity-types.yaml) — entity type NOT validated',
    };
  }
  if (!entityType) {
    return {
      ok: false,
      message:
        'entityType is required. Pass --type <Kind>. Valid kinds:\n  ' +
        [...ontology.kinds].sort().join(', '),
    };
  }
  if (ontology.kinds.has(entityType)) return { ok: true, type: entityType };

  if (ontology.aliases.has(entityType)) {
    const target = ontology.aliases.get(entityType);
    // Rewrite rather than reject: the alias map exists precisely to say "this
    // name means that kind", so honouring it silently is the point.
    return { ok: true, type: target, rewrittenFrom: entityType };
  }

  const near = suggest(entityType, ontology.kinds);
  return {
    ok: false,
    message:
      `entityType "${entityType}" is not in the ontology.` +
      (near ? `\n  Did you mean: ${near}?` : '') +
      '\n  Valid kinds: ' +
      [...ontology.kinds].sort().join(', ') +
      '\n\n  If this genuinely needs a NEW kind, that is a blast-radius change:' +
      '\n  edit doxa-cns/ontology/entity-types.yaml (or add an alias) and take it' +
      '\n  through the ontology-reviewer gate. Do not invent a type here.',
  };
}

module.exports = { checkEntityType, parseEntityTypes, loadOntology };
