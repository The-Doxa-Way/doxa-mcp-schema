/**
 * atomic.js — crash-safe file writes (tmp + fsync + rename).
 *
 * Replaces direct fs.writeFileSync for durable full-file overwrites under
 * sources/, index/, events/, authority/, conflicts/. A torn writeFileSync
 * corrupts the WHOLE file; tmp+rename gives atomicity (readers never see a
 * partial file) and the fsync gives durability (survives kill -9 / power loss).
 *
 * Matches the existing tmp.<pid> + renameSync convention already used in
 * scripts/lib/heartbeat.js and mcp/cns-server/lib/store.js — this adds the
 * fsync those older callers omit, and a best-effort directory fsync so the
 * rename itself is durable.
 *
 * Append-only logs (*.jsonl) deliberately keep appendFileSync: a torn append
 * loses at most the trailing line, not the whole file.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

let counter = 0;

/**
 * Atomically write `contents` to `filePath`. Creates parent dirs as needed.
 * @param {string} filePath
 * @param {string|Buffer} contents
 * @param {Object} [opts]
 * @param {() => boolean} [opts.precheck] Optional guard run AFTER the tmp file
 *   is fsync'd but BEFORE the rename. Return false to abort: the tmp file is
 *   removed and `filePath` is left untouched, and an Error (with
 *   `.precheckFailed = true`) is thrown instead of completing the rename.
 *   Use this to detect a concurrent external writer (e.g. re-stat the target
 *   and compare mtime to a value captured before the read) when `filePath` is
 *   a LIVE file another process/tool may also write — the default (no
 *   precheck) is unaffected and behaves exactly as before.
 * @param {string} [opts.precheckMessage] Error message when precheck fails.
 */
function atomicWrite(filePath, contents, opts = {}) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });

  // Unique tmp name: pid + monotonic counter avoids collision when a single
  // process writes several files (e.g. one snapshot per source in a sync run).
  const tmp = `${filePath}.tmp.${process.pid}.${counter++}`;

  const fd = fs.openSync(tmp, 'w');
  try {
    fs.writeFileSync(fd, contents);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }

  if (typeof opts.precheck === 'function') {
    let precheckOk;
    try {
      precheckOk = opts.precheck();
    } catch (precheckErr) {
      // A THROWING precheck must not orphan the fsync'd tmp file — clean it
      // up the same as a returned-false precheck, then propagate the
      // original error (not precheckFailed: the precheck itself errored,
      // it didn't cleanly report "changed").
      try {
        fs.unlinkSync(tmp);
      } catch {
        /* best effort cleanup */
      }
      throw precheckErr;
    }
    if (!precheckOk) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        /* best effort cleanup */
      }
      const err = new Error(opts.precheckMessage || `atomicWrite: precheck failed for ${filePath}, write aborted`);
      err.precheckFailed = true;
      throw err;
    }
  }

  fs.renameSync(tmp, filePath);

  // Best-effort directory fsync so the rename survives power loss. Not all
  // platforms/filesystems support fsync on a directory fd — ignore failures.
  try {
    const dfd = fs.openSync(dir, 'r');
    try {
      fs.fsyncSync(dfd);
    } finally {
      fs.closeSync(dfd);
    }
  } catch {
    /* directory fsync is best-effort */
  }
}

/** Convenience: atomically write a pretty-printed JSON object. */
function atomicWriteJSON(filePath, obj) {
  atomicWrite(filePath, JSON.stringify(obj, null, 2));
}

/** sha256 hex of a string/Buffer — the content fingerprint used by
 *  atomicWriteGuarded's concurrent-writer precheck. */
function hashContent(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

/**
 * atomicWrite that ABORTS (throws, with `.precheckFailed = true`) when
 * `filePath`'s current on-disk content no longer hashes to `expectedHash` —
 * i.e. a concurrent external writer changed the file between the caller's read
 * and this write. Re-reads + re-hashes rather than comparing mtime: a write
 * landing in the same mtime-resolution window as the caller's read is invisible
 * to an mtime comparison but always changes the hash. Pass
 * `expectedHash = hashContent(rawContentTheCallerRead)`.
 *
 * On a genuine overwrite of a LIVE source file (e.g. a repo's own graph.json
 * that its /kg-save or a second apply run may also write), this is the guard
 * that prevents a silent blind-clobber: the losing writer aborts loudly instead
 * of discarding the other's write. A missing/unreadable target counts as
 * changed (returns false → abort) — never clobber what you can't verify.
 */
function atomicWriteGuarded(filePath, contents, expectedHash, precheckMessage) {
  atomicWrite(filePath, contents, {
    precheck: () => {
      let current;
      try {
        current = fs.readFileSync(filePath, 'utf8');
      } catch {
        return false; // vanished/unreadable — treat as changed, don't clobber
      }
      return hashContent(current) === expectedHash;
    },
    precheckMessage,
  });
}

module.exports = { atomicWrite, atomicWriteJSON, hashContent, atomicWriteGuarded };
