#!/usr/bin/env node

/**
 * Knowledge Graph Merkle Tree Integration
 *
 * Provides mathematically verified knowledge graph operations:
 * - Automatic provenance generation with file hashes
 * - Merkle tree maintenance for integrity verification
 * - Verification on read operations
 *
 * Usage in Claude Code:
 *   1. Run: node scripts/knowledge-graph-merkle.js init
 *   2. Run: node scripts/knowledge-graph-merkle.js add "<Entity>" "<obs>" "<file>" <line> --type <Type>
 *   3. Run: node scripts/knowledge-graph-merkle.js verify
 *
 * @see KNOWLEDGE_GRAPH_PROOF_SYSTEM.md for full specification
 */

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { atomicWriteJSON } = require('./lib/atomic');

// File paths
const MERKLE_STATE_FILE = path.join(__dirname, '../.knowledge-graph-merkle.json');
const GRAPH_FILE = path.join(__dirname, '../.knowledge-graph/graph.json');
const PROJECT_ROOT = path.join(__dirname, '..');

// ANSI colors
const c = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  cyan: '\x1b[36m',
  magenta: '\x1b[35m'
};

/**
 * Cryptographic Utilities
 */
function sha256(content) {
  return crypto.createHash('sha256').update(content, 'utf8').digest('hex');
}

function buildMerkleTree(hashes) {
  if (hashes.length === 0) return sha256('empty');
  if (hashes.length === 1) return hashes[0];

  const nextLevel = [];
  for (let i = 0; i < hashes.length; i += 2) {
    const left = hashes[i];
    const right = hashes[i + 1] || left; // Duplicate if odd
    nextLevel.push(sha256(left + right));
  }

  return buildMerkleTree(nextLevel);
}

function generateMerkleProof(hashes, index) {
  if (hashes.length <= 1) return [];

  const proof = [];
  let currentIndex = index;

  while (hashes.length > 1) {
    const isRightNode = currentIndex % 2 === 1;
    const siblingIndex = isRightNode ? currentIndex - 1 : currentIndex + 1;

    if (siblingIndex < hashes.length) {
      proof.push({
        hash: hashes[siblingIndex],
        position: isRightNode ? 'left' : 'right'
      });
    } else {
      // Odd tail node: buildMerkleTree pairs it with itself
      // (right = hashes[i+1] || left) instead of dropping the step. Mirror
      // that here or the proof for the last leaf on an odd level fails
      // verification even though the leaf is untampered.
      proof.push({
        hash: hashes[currentIndex],
        position: 'right'
      });
    }

    // Build next level
    const nextLevel = [];
    for (let i = 0; i < hashes.length; i += 2) {
      const left = hashes[i];
      const right = hashes[i + 1] || left;
      nextLevel.push(sha256(left + right));
    }

    hashes = nextLevel;
    currentIndex = Math.floor(currentIndex / 2);
  }

  return proof;
}

function verifyMerkleProof(leafHash, proof, merkleRoot) {
  let currentHash = leafHash;

  for (const step of proof) {
    if (step.position === 'left') {
      currentHash = sha256(step.hash + currentHash);
    } else {
      currentHash = sha256(currentHash + step.hash);
    }
  }

  return currentHash === merkleRoot;
}

/**
 * Merkle State Management
 */
/**
 * Graph self-healing (Phase 7C-compliant)
 * ----------------------------------------
 * The merkle state is THIS repo's authoritative record of observations
 * we've added via merkle-add. graph.json is what doxa-cns reads at 05:05.
 * They can drift apart if merkle-add was called but graph.json wasn't
 * touched (every prior session prior to this fix).
 *
 * The self-healer reconciles by:
 *   1. Reading merkle state (every observation we authored)
 *   2. Reading graph.json (current source-of-truth file)
 *   3. For each merkle observation: ensure it's in graph.json's entity
 *      observations[]. Create the entity if missing (type=Unknown unless
 *      provided via --type at add time, which gets stored in merkle
 *      provenance.entityType).
 *
 * No cloud-KG read — Phase 7C-compliant. We never pull from the in-session
 * memory MCP because that would contaminate this repo with cross-repo
 * entities.
 */
function loadGraph() {
  if (!fs.existsSync(GRAPH_FILE)) {
    return { entities: [], relations: [] };
  }
  const data = JSON.parse(fs.readFileSync(GRAPH_FILE, 'utf8'));
  // Normalise schema — always return {entities: [...], relations: [...]}
  return {
    entities: Array.isArray(data.entities) ? data.entities : [],
    relations: Array.isArray(data.relations) ? data.relations : [],
  };
}

function saveGraph(graph) {
  // Atomic write: pid+counter-unique tmp name + fsync (atomicWriteJSON),
  // matching saveMerkleState below. The old inline `tmp = GRAPH_FILE +
  // '.tmp'` + writeFileSync + renameSync had neither: a fixed, non-unique
  // tmp filename that two concurrent `add` invocations can race on, and no
  // fsync, so a crash mid-write could leave a torn or missing file.
  // atomicWriteJSON creates its own parent dir, so no separate mkdir here.
  // (2026-08-11 fix, ported from doxa-cns's canonical file.)
  atomicWriteJSON(GRAPH_FILE, graph);
  // The generator owns its derived output: every graph write refreshes the
  // cheap navigation surface (.knowledge-graph/INDEX.md) so it can never
  // drift. Failure here must not lose the graph write itself — warn loud.
  try {
    require('./kg-index.js').regenerate();
  } catch (err) {
    console.error(`WARN: INDEX.md regeneration failed: ${err.message} — run scripts/kg-index.js`);
  }
}

/**
 * Reconcile a single (entity, observation) pair into graph.json.
 * Returns {created: bool, appended: bool} so the caller can summarise.
 *
 * Idempotent — re-running on the same observation does nothing.
 */
function reconcileObservationIntoGraph(entityName, observationContent, entityType) {
  const graph = loadGraph();
  let entity = graph.entities.find(e => e.name === entityName);
  let created = false;
  let appended = false;
  let typeUpgraded = false;

  if (!entity) {
    entity = {
      name: entityName,
      entityType: entityType || 'Unknown',
      observations: [],
    };
    graph.entities.push(entity);
    created = true;
  } else if (entityType && entity.entityType === 'Unknown' && entityType !== 'Unknown') {
    // Upgrade Unknown → real type if we now have one
    entity.entityType = entityType;
    typeUpgraded = true;
  }

  if (!entity.observations.includes(observationContent)) {
    entity.observations.push(observationContent);
    appended = true;
  }

  // Bug fix (2026-07-14): a --type upgrade on an entity whose observation was
  // already present (dedup, appended=false) was silently discarded because
  // the save was gated on created||appended only. typeUpgraded now keeps the
  // write path honest with what actually changed in memory.
  if (created || appended || typeUpgraded) saveGraph(graph);
  return { created, appended, typeUpgraded };
}

/**
 * Backfill graph.json from the merkle state. Walks every observation in
 * .knowledge-graph-merkle.json and ensures graph.json has it. Safe to
 * re-run — idempotent.
 *
 * This is the cron-friendly "self-heal" command.
 */
function reconcile() {
  const state = loadMerkleState();
  const graph = loadGraph();
  let createdCount = 0;
  let appendedCount = 0;
  let unchangedCount = 0;
  let typesGuessed = 0;

  // Track entities we've already updated this run so we batch the work
  const entityIdx = new Map();
  for (const e of graph.entities) entityIdx.set(e.name, e);

  for (const obs of state.observations || []) {
    let entity = entityIdx.get(obs.entityName);
    let entityChanged = false;
    const entityType = obs.provenance?.entityType || null;

    if (!entity) {
      entity = {
        name: obs.entityName,
        entityType: entityType || 'Unknown',
        observations: [],
      };
      graph.entities.push(entity);
      entityIdx.set(obs.entityName, entity);
      createdCount++;
      entityChanged = true;
      if (!entityType) typesGuessed++;
    } else if (entityType && entity.entityType === 'Unknown' && entityType !== 'Unknown') {
      entity.entityType = entityType;
      entityChanged = true;
    }

    if (!entity.observations.includes(obs.content)) {
      entity.observations.push(obs.content);
      appendedCount++;
      entityChanged = true;
    }

    if (!entityChanged) unchangedCount++;
  }

  saveGraph(graph);
  return { createdCount, appendedCount, unchangedCount, typesGuessed };
}

function loadMerkleState() {
  if (fs.existsSync(MERKLE_STATE_FILE)) {
    return JSON.parse(fs.readFileSync(MERKLE_STATE_FILE, 'utf8'));
  }
  return {
    merkleRoot: null,
    observations: [], // Array of { hash, entityName, observationContent, provenance, timestamp }
    lastVerified: null,
    version: 1
  };
}

function saveMerkleState(state) {
  state.lastModified = new Date().toISOString();
  // Atomic write: tmp + rename (+ fsync), matching saveGraph above. A plain
  // writeFileSync here can be torn by a crash/kill mid-write, and every
  // subcommand (loadMerkleState) does an unguarded JSON.parse on this file —
  // a torn write bricks the whole tool.
  atomicWriteJSON(MERKLE_STATE_FILE, state);
}

/**
 * Generate provenance for an observation
 */
function generateProvenance(sourceFile, lineNumber = null, lineRange = null) {
  const fullPath = path.join(PROJECT_ROOT, sourceFile);

  if (!fs.existsSync(fullPath)) {
    return {
      sourceFile,
      fileHash: null,
      extractedAt: new Date().toISOString(),
      verificationStatus: 'unverified',
      error: 'Source file not found'
    };
  }

  const content = fs.readFileSync(fullPath, 'utf8');
  const fileHash = sha256(content);
  const lines = content.split('\n');

  return {
    sourceFile,
    lineNumber,
    lineRange,
    fileHash,
    totalLines: lines.length,
    extractedAt: new Date().toISOString(),
    verificationStatus: 'verified',
    extractedBy: 'knowledge-graph-merkle.js'
  };
}

/**
 * Create observation with provenance and add to Merkle tree
 */
function createVerifiedObservation(entityName, observationContent, sourceFile, lineNumber = null) {
  const state = loadMerkleState();

  // Generate provenance
  const provenance = generateProvenance(sourceFile, lineNumber);

  // Create observation record
  const observationRecord = {
    entityName,
    content: observationContent,
    provenance,
    timestamp: new Date().toISOString()
  };

  // Hash the observation
  const observationHash = sha256(JSON.stringify(observationRecord));

  // Add to state
  state.observations.push({
    hash: observationHash,
    ...observationRecord
  });

  // Rebuild Merkle tree
  const allHashes = state.observations.map(o => o.hash);
  state.merkleRoot = buildMerkleTree(allHashes);

  // Save state
  saveMerkleState(state);

  return {
    observationHash,
    merkleRoot: state.merkleRoot,
    provenance
  };
}

/**
 * Verify entire knowledge graph
 */
function verifyKnowledgeGraph() {
  const state = loadMerkleState();
  const results = {
    status: 'VERIFIED',
    merkleRoot: state.merkleRoot,
    totalObservations: state.observations.length,
    violations: [],
    warnings: [],
    staleFiles: []
  };

  console.log(`\n${c.cyan}Verifying Knowledge Graph...${c.reset}\n`);

  for (const obs of state.observations) {
    // Verify observation hash
    const recomputedHash = sha256(JSON.stringify({
      entityName: obs.entityName,
      content: obs.content,
      provenance: obs.provenance,
      timestamp: obs.timestamp
    }));

    if (recomputedHash !== obs.hash) {
      results.violations.push({
        type: 'HASH_MISMATCH',
        entity: obs.entityName,
        message: 'Observation hash does not match stored hash - possible tampering'
      });
      results.status = 'VIOLATIONS';
    }

    // Verify source file integrity
    if (obs.provenance?.sourceFile) {
      const fullPath = path.join(PROJECT_ROOT, obs.provenance.sourceFile);

      if (!fs.existsSync(fullPath)) {
        results.warnings.push({
          type: 'FILE_MISSING',
          entity: obs.entityName,
          file: obs.provenance.sourceFile,
          message: 'Source file no longer exists'
        });
        if (results.status === 'VERIFIED') results.status = 'WARNINGS';
      } else {
        const currentContent = fs.readFileSync(fullPath, 'utf8');
        const currentHash = sha256(currentContent);

        if (currentHash !== obs.provenance.fileHash) {
          results.staleFiles.push({
            entity: obs.entityName,
            file: obs.provenance.sourceFile,
            originalHash: obs.provenance.fileHash?.substring(0, 12),
            currentHash: currentHash.substring(0, 12)
          });
          results.warnings.push({
            type: 'FILE_CHANGED',
            entity: obs.entityName,
            file: obs.provenance.sourceFile,
            message: 'Source file has been modified since observation was created'
          });
          if (results.status === 'VERIFIED') results.status = 'WARNINGS';
        }
      }
    }
  }

  // Verify Merkle root
  const allHashes = state.observations.map(o => o.hash);
  const recomputedRoot = buildMerkleTree(allHashes);

  if (recomputedRoot !== state.merkleRoot) {
    results.violations.push({
      type: 'MERKLE_ROOT_MISMATCH',
      message: 'Merkle root does not match - graph integrity compromised'
    });
    results.status = 'VIOLATIONS';
  }

  // Update last verified and persist. saveMerkleState writes atomically
  // (tmp + rename + fsync), so there's no torn-write hazard to a `status`
  // reader racing this write — the skip-rewrite optimisation that used to
  // guard against that is no longer needed, and it was masking lastVerified
  // from ever advancing on a clean (no-violation) verify run.
  state.lastVerified = new Date().toISOString();
  saveMerkleState(state);

  return results;
}

/**
 * CLI Interface
 */
function printHelp() {
  console.log(`
${c.bright}${c.magenta}Knowledge Graph Merkle Tree System${c.reset}

${c.bright}Commands:${c.reset}

  ${c.green}init${c.reset}
    Initialize or reset the Merkle state file

  ${c.green}add <entity> <observation> <source-file> [line-number] [--type <EntityType>]${c.reset}
    Add a verified observation with provenance. Auto-reconciles into
    .knowledge-graph/graph.json so doxa-cns sees it at next 05:05 sync.
    Pass --type for NEW entities so reconcile records the right type
    (defaults to Unknown). Idempotent on re-runs.
    Example: node scripts/knowledge-graph-merkle.js add Design_System "Button height is 48pt" CLAUDE.md 45 --type System

  ${c.green}reconcile${c.reset}
    Self-heal .knowledge-graph/graph.json from the merkle state. Backfills
    any observations/entities that exist in the merkle audit trail but are
    missing from graph.json. Safe to re-run. Useful after batch edits.

  ${c.green}reconcile${c.reset}
    Self-heal .knowledge-graph/graph.json from the merkle state. Backfills
    any observations/entities that exist in the merkle audit trail but are
    missing from graph.json. Safe to re-run. Useful after batch edits.

  ${c.green}merge-resolve <ours-file> <theirs-file>${c.reset}
    MANDATORY whenever git reports a conflict on .knowledge-graph-merkle.json
    or .knowledge-graph/graph.json. NEVER resolve those conflicts with
    'git checkout --ours'/'--theirs' — the observations array is an append
    log, and picking a side silently discards the other side's KG entries
    (this is how a real bug shipped with no KG record of it once — see the
    comment on mergeResolve() in this file). Unions both sides by hash
    (nothing is ever dropped), rebuilds the Merkle root, and reconciles
    graph.json from the result.
    Example: git show :2:.knowledge-graph-merkle.json > /tmp/ours.json
             git show :3:.knowledge-graph-merkle.json > /tmp/theirs.json
             node scripts/knowledge-graph-merkle.js merge-resolve /tmp/ours.json /tmp/theirs.json


  ${c.green}verify${c.reset}
    Verify the entire knowledge graph integrity

  ${c.green}status${c.reset}
    Show current Merkle tree status

  ${c.green}proof <index>${c.reset}
    Generate Merkle proof for observation at index

  ${c.green}export${c.reset}
    Export all observations with full provenance

  ${c.green}rehash${c.reset}
    Update file hashes for stale observations after code changes
    Use this after committing changes to refresh provenance

${c.bright}How it works:${c.reset}
  1. When you add an observation, it generates provenance (file hash, line number)
  2. The observation is hashed and added to a Merkle tree
  3. The Merkle root changes with every update
  4. On verify, all hashes are recomputed to detect tampering
  5. Source files are checked to detect stale observations
`);
}

function init() {
  const state = {
    merkleRoot: sha256('empty'),
    observations: [],
    lastVerified: null,
    version: 1,
    createdAt: new Date().toISOString()
  };
  saveMerkleState(state);
  console.log(`${c.green}Initialized Merkle state at ${MERKLE_STATE_FILE}${c.reset}`);
  console.log(`${c.cyan}Merkle Root: ${state.merkleRoot.substring(0, 32)}...${c.reset}`);
}

function status() {
  const state = loadMerkleState();

  console.log(`\n${c.bright}${c.cyan}Knowledge Graph Merkle Status${c.reset}\n`);
  console.log(`${c.bright}Merkle Root:${c.reset} ${state.merkleRoot?.substring(0, 32) || 'none'}...`);
  console.log(`${c.bright}Observations:${c.reset} ${state.observations.length}`);
  console.log(`${c.bright}Last Modified:${c.reset} ${state.lastModified || 'never'}`);
  console.log(`${c.bright}Last Verified:${c.reset} ${state.lastVerified || 'never'}`);

  if (state.observations.length > 0) {
    console.log(`\n${c.bright}Recent Observations:${c.reset}`);
    state.observations.slice(-5).forEach((obs, i) => {
      console.log(`  ${i + 1}. [${obs.entityName}] ${obs.content.substring(0, 50)}...`);
      console.log(`     ${c.cyan}Hash: ${obs.hash.substring(0, 16)}... | Source: ${obs.provenance?.sourceFile || 'none'}${c.reset}`);
    });
  }
}

function add(args) {
  if (args.length < 3) {
    console.log(`${c.red}Usage: add <entity> <observation> <source-file> [line-number] [--type <entityType>]${c.reset}`);
    return;
  }

  // Parse positional + flags. Accept --type <Foo> anywhere after the first 3 positionals.
  let entityType = null;
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--type' && args[i + 1]) {
      entityType = args[i + 1];
      i++;
    } else {
      positional.push(args[i]);
    }
  }

  // Guard: a trailing --type with no value falls through the loop above into
  // `positional` as a plain string, since `args[i + 1]` is undefined and the
  // `--type` branch never fires. Left unguarded, it silently becomes
  // sourceFile/lineNumber/an extra positional below — for an EXISTING entity
  // (--type is optional there) this used to persist a NaN line number into
  // provenance with NO error surfaced at all. Reject loudly instead (2026-08-11
  // fix, ported from doxa-cns's canonical file).
  if (positional.includes('--type')) {
    console.log(`${c.red}--type given with no value after it.${c.reset}\n` +
      `${c.yellow}Usage: add <entity> <observation> <source-file> [line] --type <EntityType>${c.reset}`);
    process.exitCode = 1;
    return;
  }
  const [entityName, observation, sourceFile, lineNumber] = positional;

  // Guard: an entity name starting with '-' is almost always a CLI flag that a
  // caller mis-passed into the positional <entity> slot (e.g. invoking
  // `add --entity "Foo" ...` — argv lands "--entity" as the name and the intended
  // name "Foo" as the observation). This recurringly created a junk "--entity"
  // (type Unknown) entity in the meta-KG. Reject at the point of entry so no buggy
  // caller can recreate it, whatever automation invokes us.
  if (typeof entityName === 'string' && entityName.startsWith('-')) {
    console.log(
      `${c.red}Refusing entity name "${entityName}": looks like a mis-parsed CLI flag, not an entity name.${c.reset}\n` +
      `${c.yellow}Pass flags AFTER the positionals: add <entity> <observation> <source-file> [line] [--type <T>]${c.reset}`
    );
    process.exitCode = 1;
    return;
  }

  // Ontology guard (Garth 2026-08-02, "kg discipline up to scratch"). Two
  // distinct drift sources, both closed here rather than reported later by
  // kg-audit-all.js — a report nobody is blocked by is a report nobody acts on.
  //
  //   1. An INVENTED type. 80 off-ontology entities had accumulated across the
  //      four repos; I added two of them the same evening I wrote the doctrine
  //      telling others not to. Rejected now, with the nearest legal kind named.
  //   2. A MISSING type on a NEW entity, which silently became `Unknown` — by
  //      far the largest drift class (68 entities). Now refused.
  //
  // Appending to an EXISTING entity may still omit --type: the entity already
  // has one, and demanding it again would break every legitimate append.
  {
    const { checkEntityType } = require('./lib/ontology-guard.js');
    if (entityType) {
      const verdict = checkEntityType(entityType);
      if (!verdict.ok) {
        console.log(`${c.red}${verdict.message}${c.reset}`);
        process.exitCode = 1;
        return;
      }
      if (verdict.warning) console.log(`${c.yellow}⚠ ${verdict.warning}${c.reset}`);
      if (verdict.rewrittenFrom) {
        console.log(`${c.yellow}note: "${verdict.rewrittenFrom}" is an alias — recorded as "${verdict.type}"${c.reset}`);
      }
      entityType = verdict.type;
    } else {
      const graphPeek = loadGraph();
      const exists = (graphPeek.entities || []).some((e) => e.name === entityName);
      if (!exists) {
        const { loadOntology } = require('./lib/ontology-guard.js');
        const ont = loadOntology();
        console.log(
          `${c.red}New entity "${entityName}" needs an explicit --type.${c.reset}\n` +
          `${c.yellow}Untyped entities were silently recorded as "Unknown" — the single largest\n` +
          `source of ontology drift in the fleet. Pick the kind that fits:${c.reset}\n  ` +
          (ont ? [...ont.kinds].sort().join(', ') : '(ontology unreadable — see doxa-cns/ontology/entity-types.yaml)')
        );
        process.exitCode = 1;
        return;
      }
    }
  }

  console.log(`\n${c.cyan}Adding verified observation...${c.reset}\n`);

  const result = createVerifiedObservation(
    entityName,
    observation,
    sourceFile,
    lineNumber ? parseInt(lineNumber) : null
  );

  // Persist entityType into the merkle observation's provenance so future
  // reconcile runs can backfill graph.json with the correct type instead
  // of "Unknown". Mutates the just-added observation in-place + re-saves.
  if (entityType) {
    const state = loadMerkleState();
    const lastObs = state.observations[state.observations.length - 1];
    if (lastObs && lastObs.entityName === entityName && lastObs.hash === result.observationHash) {
      lastObs.provenance.entityType = entityType;
      // entityType becomes part of the signed record — recompute obs.hash
      // and merkle root so verify still passes. Without this, every typed
      // observation fails verification because its stored hash was computed
      // before provenance was mutated.
      lastObs.hash = sha256(JSON.stringify({
        entityName: lastObs.entityName,
        content: lastObs.content,
        provenance: lastObs.provenance,
        timestamp: lastObs.timestamp,
      }));
      state.merkleRoot = buildMerkleTree(state.observations.map((o) => o.hash));
      saveMerkleState(state);
    }
  }

  console.log(`${c.green}Observation added to Merkle tree${c.reset}`);
  console.log(`${c.bright}Hash:${c.reset} ${result.observationHash.substring(0, 32)}...`);
  console.log(`${c.bright}New Merkle Root:${c.reset} ${result.merkleRoot.substring(0, 32)}...`);
  console.log(`${c.bright}Source Hash:${c.reset} ${result.provenance.fileHash?.substring(0, 32) || 'none'}...`);

  // Self-heal graph.json — write the same observation into the local
  // source-of-truth file so doxa-cns at 05:05 has it. Idempotent.
  const reconcileResult = reconcileObservationIntoGraph(entityName, observation, entityType);
  if (reconcileResult.created) {
    console.log(`${c.green}Graph: created entity ${entityName} (type=${entityType || 'Unknown'})${c.reset}`);
    if (!entityType) {
      console.log(`${c.yellow}  hint: pass --type <EntityType> next time so reconcile doesn't default to Unknown${c.reset}`);
    }
  } else if (reconcileResult.appended) {
    console.log(`${c.green}Graph: appended observation to existing ${entityName}${c.reset}`);
  } else {
    console.log(`${c.cyan}Graph: already present (idempotent no-op)${c.reset}`);
  }

  if (reconcileResult.typeUpgraded) {
    const suffix = reconcileResult.appended ? '' : ' (observation already present)';
    console.log(`${c.green}Graph: entityType upgraded Unknown -> ${entityType}${suffix}${c.reset}`);
  }
}

function runReconcile() {
  console.log(`\n${c.cyan}Reconciling .knowledge-graph/graph.json from merkle state...${c.reset}\n`);
  const result = reconcile();
  console.log(`${c.green}Entities created:${c.reset}        ${result.createdCount}`);
  console.log(`${c.green}Observations appended:${c.reset}   ${result.appendedCount}`);
  console.log(`${c.cyan}Already in sync:${c.reset}          ${result.unchangedCount}`);
  if (result.typesGuessed > 0) {
    console.log(`${c.yellow}Created with type=Unknown:${c.reset}  ${result.typesGuessed}`);
    console.log(`${c.yellow}  (no entityType stored in merkle provenance; pass --type on future add calls)${c.reset}`);
  }
}

/**
 * Merge-conflict resolver for .knowledge-graph-merkle.json (2026-08-13,
 * Garth: "this should be standing doctrine and practice across all repos").
 *
 * The merkle observations array is an APPEND LOG: two branches can each add
 * observations the other doesn't have. A conflict on this file is NEVER
 * safe to resolve with `git checkout --ours`/`--theirs` — whichever side
 * loses is silently dropped, code and all, with no error anywhere (this is
 * exactly how PR #343's KgAddTrailingTypeFlagFix entity vanished: taking
 * origin/main's merkle.json wholesale during a conflict discarded the
 * branch's own observation, and the planned "re-add it after" step was
 * skipped — the bug shipped correctly, its KG record didn't).
 *
 * mergeResolve(oursPath, theirsPath) unions both sides' observations by
 * hash (each observation's hash is content-addressed and unique, so a
 * hash-keyed union can never duplicate or silently prefer one side), sorts
 * by timestamp for a deterministic result regardless of arg order, rebuilds
 * the Merkle root from the unioned set, writes it as THIS repo's current
 * merkle state, then reconciles graph.json from it — so both the audit
 * trail and the projection are guaranteed complete, no matter which side of
 * the conflict "won" for every other file.
 */
function mergeResolve(oursPath, theirsPath) {
  if (!oursPath || !theirsPath) {
    console.log(`${c.red}Usage: merge-resolve <ours-file> <theirs-file>${c.reset}`);
    console.log(`${c.yellow}Typically: git show :2:.knowledge-graph-merkle.json > /tmp/ours.json${c.reset}`);
    console.log(`${c.yellow}           git show :3:.knowledge-graph-merkle.json > /tmp/theirs.json${c.reset}`);
    console.log(`${c.yellow}           node scripts/knowledge-graph-merkle.js merge-resolve /tmp/ours.json /tmp/theirs.json${c.reset}`);
    process.exitCode = 1;
    return;
  }

  const ours = JSON.parse(fs.readFileSync(oursPath, 'utf8'));
  const theirs = JSON.parse(fs.readFileSync(theirsPath, 'utf8'));

  const byHash = new Map();
  for (const obs of [...(ours.observations || []), ...(theirs.observations || [])]) {
    byHash.set(obs.hash, obs); // hash-keyed: identical observations collapse, never duplicate
  }
  const merged = [...byHash.values()].sort((a, b) =>
    (a.timestamp || '').localeCompare(b.timestamp || ''));

  const oursCount = (ours.observations || []).length;
  const theirsCount = (theirs.observations || []).length;
  const onlyInOurs = merged.length - theirsCount;
  const onlyInTheirs = merged.length - oursCount;

  const state = {
    merkleRoot: buildMerkleTree(merged.map((o) => o.hash)),
    observations: merged,
    lastVerified: null,
    version: 1,
  };
  saveMerkleState(state);

  console.log(`\n${c.cyan}Merged merkle state: ${oursCount} (ours) + ${theirsCount} (theirs) -> ${merged.length} (unioned, deduped by hash)${c.reset}`);
  if (onlyInOurs > 0) console.log(`${c.green}  ${onlyInOurs} observation(s) unique to ours — preserved${c.reset}`);
  if (onlyInTheirs > 0) console.log(`${c.green}  ${onlyInTheirs} observation(s) unique to theirs — preserved${c.reset}`);

  console.log(`\n${c.cyan}Reconciling .knowledge-graph/graph.json from the merged state...${c.reset}`);
  const result = reconcile();
  console.log(`${c.green}Entities created:${c.reset}        ${result.createdCount}`);
  console.log(`${c.green}Observations appended:${c.reset}   ${result.appendedCount}`);
  console.log(`\n${c.bright}Resolved. Now: git add .knowledge-graph-merkle.json .knowledge-graph/graph.json .knowledge-graph/INDEX.md${c.reset}`);
}

function verify() {
  const results = verifyKnowledgeGraph();

  console.log(`\n${c.bright}${'='.repeat(50)}${c.reset}`);

  const statusEmoji = results.status === 'VERIFIED' ? '?'
                    : results.status === 'WARNINGS' ? '??'
                    : '?';

  console.log(`${c.bright}Status: ${statusEmoji} ${results.status}${c.reset}`);
  console.log(`${c.bright}${'='.repeat(50)}${c.reset}`);
  console.log(`Merkle Root: ${results.merkleRoot?.substring(0, 32) || 'none'}...`);
  console.log(`Total Observations: ${results.totalObservations}`);
  console.log(`Violations: ${results.violations.length}`);
  console.log(`Warnings: ${results.warnings.length}`);
  console.log(`Stale Files: ${results.staleFiles.length}`);

  if (results.violations.length > 0) {
    console.log(`\n${c.red}VIOLATIONS:${c.reset}`);
    results.violations.forEach((v, i) => {
      console.log(`  ${i + 1}. [${v.type}] ${v.message}`);
      if (v.entity) console.log(`     Entity: ${v.entity}`);
    });
  }

  if (results.warnings.length > 0) {
    console.log(`\n${c.yellow}WARNINGS:${c.reset}`);
    results.warnings.forEach((w, i) => {
      console.log(`  ${i + 1}. [${w.type}] ${w.message}`);
      if (w.entity) console.log(`     Entity: ${w.entity}`);
    });
  }

  if (results.staleFiles.length > 0) {
    console.log(`\n${c.yellow}STALE FILES (source changed since observation):${c.reset}`);
    results.staleFiles.forEach((f, i) => {
      console.log(`  ${i + 1}. ${f.file}`);
      console.log(`     Entity: ${f.entity}`);
      console.log(`     Original: ${f.originalHash}... -> Current: ${f.currentHash}...`);
    });
  }

  console.log('');
}

function proof(args) {
  if (args.length < 1) {
    console.log(`${c.red}Usage: proof <index>${c.reset}`);
    return;
  }

  const index = parseInt(args[0]);
  const state = loadMerkleState();

  if (index < 0 || index >= state.observations.length) {
    console.log(`${c.red}Invalid index. Valid range: 0-${state.observations.length - 1}${c.reset}`);
    return;
  }

  const obs = state.observations[index];
  const allHashes = state.observations.map(o => o.hash);
  const proof = generateMerkleProof([...allHashes], index);

  console.log(`\n${c.bright}Merkle Proof for Observation ${index}${c.reset}\n`);
  console.log(`${c.bright}Entity:${c.reset} ${obs.entityName}`);
  console.log(`${c.bright}Content:${c.reset} ${obs.content.substring(0, 60)}...`);
  console.log(`${c.bright}Leaf Hash:${c.reset} ${obs.hash}`);
  console.log(`${c.bright}Merkle Root:${c.reset} ${state.merkleRoot}`);
  console.log(`\n${c.bright}Proof Path:${c.reset}`);
  proof.forEach((step, i) => {
    console.log(`  ${i + 1}. ${step.position}: ${step.hash.substring(0, 32)}...`);
  });

  // Verify the proof
  const isValid = verifyMerkleProof(obs.hash, proof, state.merkleRoot);
  console.log(`\n${c.bright}Proof Valid:${c.reset} ${isValid ? `${c.green}YES${c.reset}` : `${c.red}NO${c.reset}`}`);
}

function exportObservations() {
  const state = loadMerkleState();

  const exportData = {
    merkleRoot: state.merkleRoot,
    exportedAt: new Date().toISOString(),
    observations: state.observations.map(obs => ({
      entity: obs.entityName,
      content: obs.content,
      hash: obs.hash,
      provenance: obs.provenance,
      timestamp: obs.timestamp
    }))
  };

  const filename = `knowledge-graph-export-${Date.now()}.json`;
  fs.writeFileSync(filename, JSON.stringify(exportData, null, 2));
  console.log(`${c.green}Exported to ${filename}${c.reset}`);
}

/**
 * Rehash stale observations - updates file hashes to current values
 * Use after committing changes to refresh the provenance
 */
function rehash() {
  const state = loadMerkleState();
  let updated = 0;
  let skipped = 0;

  console.log(`\n${c.cyan}Rehashing stale observations...${c.reset}\n`);

  for (const obs of state.observations) {
    if (!obs.provenance?.sourceFile) {
      skipped++;
      continue;
    }

    const fullPath = path.join(PROJECT_ROOT, obs.provenance.sourceFile);

    if (!fs.existsSync(fullPath)) {
      // The file re-read is impossible, but self-hash drift (provenance
      // mutated after hashing, e.g. the entityType injection in `add`) is
      // still healable from the STORED record — verify recomputes from those
      // same stored fields, so re-signing them cannot launder content edits.
      const storedHash = sha256(JSON.stringify({
        entityName: obs.entityName,
        content: obs.content,
        provenance: obs.provenance,
        timestamp: obs.timestamp,
      }));
      if (storedHash !== obs.hash) {
        const oldHash = obs.hash?.substring(0, 12) || 'none';
        obs.hash = storedHash;
        console.log(`${c.green}  Updated: ${obs.entityName}${c.reset} (self-hash drift, source file missing)`);
        console.log(`    Hash: ${oldHash}... -> ${storedHash.substring(0, 12)}...`);
        updated++;
      } else {
        console.log(`${c.yellow}  Skipped: ${obs.provenance.sourceFile} (file not found)${c.reset}`);
        skipped++;
      }
      continue;
    }

    const currentContent = fs.readFileSync(fullPath, 'utf8');
    const currentHash = sha256(currentContent);

    const fileChanged = currentHash !== obs.provenance.fileHash;
    if (fileChanged) {
      obs.provenance.fileHash = currentHash;
      obs.provenance.totalLines = currentContent.split('\n').length;
      obs.provenance.rehashedAt = new Date().toISOString();
    }

    // Always recompute obs.hash from current provenance and check self-consistency.
    // This heals observations where provenance was mutated after the hash was
    // first computed (e.g. by the entityType-injection in `add`).
    const newObsHash = sha256(JSON.stringify({
      entityName: obs.entityName,
      content: obs.content,
      provenance: obs.provenance,
      timestamp: obs.timestamp,
    }));

    if (newObsHash !== obs.hash) {
      const oldHash = obs.hash?.substring(0, 12) || 'none';
      obs.hash = newObsHash;
      const reason = fileChanged ? 'file changed' : 'self-hash drift';
      console.log(`${c.green}  Updated: ${obs.entityName}${c.reset} (${reason})`);
      console.log(`    File: ${obs.provenance.sourceFile}`);
      console.log(`    Hash: ${oldHash}... -> ${newObsHash.substring(0, 12)}...`);
      updated++;
    } else {
      skipped++;
    }
  }

  // Rebuild Merkle tree with new hashes
  const allHashes = state.observations.map(o => o.hash);
  state.merkleRoot = buildMerkleTree(allHashes);

  saveMerkleState(state);

  console.log(`\n${c.bright}Rehash Complete${c.reset}`);
  console.log(`  Updated: ${updated}`);
  console.log(`  Skipped: ${skipped}`);
  console.log(`  New Merkle Root: ${state.merkleRoot.substring(0, 32)}...`);
}

// Main CLI — only runs when invoked directly, not on require()
if (require.main === module) {
  const command = process.argv[2];
  const args = process.argv.slice(3);

  switch (command) {
    case 'init':
      init();
      break;
    case 'add':
      add(args);
      break;
    case 'verify':
      verify();
      break;
    case 'status':
      status();
      break;
    case 'proof':
      proof(args);
      break;
    case 'export':
      exportObservations();
      break;
    case 'rehash':
      rehash();
      break;
    case 'reconcile':
      runReconcile();
      break;
    case 'merge-resolve':
      mergeResolve(args[0], args[1]);
      break;
    case 'help':
    case '--help':
    case '-h':
    default:
      printHelp();
  }
}

// Export for programmatic use
module.exports = {
  sha256,
  buildMerkleTree,
  generateMerkleProof,
  verifyMerkleProof,
  createVerifiedObservation,
  verifyKnowledgeGraph,
  loadMerkleState,
  generateProvenance
};
