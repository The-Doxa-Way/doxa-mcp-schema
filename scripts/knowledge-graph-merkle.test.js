// knowledge-graph-merkle.test.js — pins the 2026-08-11 atomic-write and
// --type-guard fixes ported from doxa-cns's canonical knowledge-graph-merkle.js.
// Source-guard style (not an execve integration test): the `add` path writes
// to the real repo's graph/merkle files, so it is deliberately not exercised
// here directly — these tests check the module source for the fix shape.
//
// Run: node --test scripts/knowledge-graph-merkle.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, 'knowledge-graph-merkle.js');

test('add() rejects a trailing --type with no value instead of silently corrupting positionals', () => {
  const src = fs.readFileSync(SRC, 'utf8');
  assert.ok(src.includes("positional.includes('--type')"), 'add() must detect a valueless trailing --type before destructuring positionals');
  const beforeDestructure = src.slice(0, src.indexOf('const [entityName, observation, sourceFile, lineNumber] = positional;'));
  assert.ok(beforeDestructure.includes("positional.includes('--type')"), 'the guard must run BEFORE the positional destructure, not after');
});

test('saveGraph writes atomically (pid+counter-unique tmp + fsync), not the old racy fixed-tmp-name pattern', () => {
  const src = fs.readFileSync(SRC, 'utf8');
  assert.ok(/function saveGraph\(graph\)/.test(src), 'saveGraph must still exist as a named function');
  assert.ok(src.includes('atomicWriteJSON(GRAPH_FILE'), 'saveGraph must delegate the write to atomicWriteJSON (pid+counter-unique tmp name + fsync), matching saveMerkleState');
  assert.strictEqual(src.includes("GRAPH_FILE + '.tmp'"), false, 'the old fixed, non-unique tmp filename must not return, two concurrent kg-save calls raced on it');
});
