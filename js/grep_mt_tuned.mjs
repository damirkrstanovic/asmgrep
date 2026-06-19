// nodegrep_std_mt_tuned - worker_threads pool, but each worker applies the two
// memory-pillar rules from c/grep_std_mt.c:
//   (a) REUSE one read buffer per worker (openSync + readSync into the reused buffer)
//       instead of allocating a fresh Buffer per file;
//   (b) read a 64KB PREFIX first, binary-check it, and read the rest ONLY if the file
//       isn't binary -- so a huge .git pack is never faulted in then skipped.
// Output is per-line atomic across workers: each worker batches WHOLE lines into its
// own Buffer and flushes with a single writeSync (one write() syscall).
//
// worker_threads is a node: API; launched under node (see launchers).

import {
  Worker, isMainThread, workerData, parentPort,
} from "node:worker_threads";
import { openSync, readSync, closeSync, writeSync } from "node:fs";
import { availableParallelism } from "node:os";
import { fileURLToPath } from "node:url";
import {
  parseArgs, lowerPattern, scan, isBinaryPrefix, collectFiles, PEEK_SIZE,
} from "./grep_core.mjs";

const SELF = fileURLToPath(import.meta.url);

function workerRun() {
  const { files, pat, ci, multi, sab } = workerData;
  const cursor = new Int32Array(sab);
  const patBuf = Buffer.from(pat, "latin1");
  const needle = ci ? lowerPattern(patBuf) : patBuf;

  const COLON = Buffer.from(":");
  const NLB = Buffer.from("\n");
  let out = Buffer.allocUnsafe(1 << 20);
  let outLen = 0;
  const FLUSH = 1 << 20;
  function ensure(n) {
    if (outLen + n <= out.length) return;
    let cap = out.length;
    while (outLen + n > cap) cap *= 2;
    const nb = Buffer.allocUnsafe(cap);
    out.copy(nb, 0, 0, outLen);
    out = nb;
  }
  function flush() { if (outLen) { writeSync(1, out, 0, outLen); outLen = 0; } }

  // REUSED per-worker buffers, grown to the largest file seen and never freed.
  let rbuf = Buffer.allocUnsafe(PEEK_SIZE);
  let lowerScratch = Buffer.allocUnsafe(0);
  let matched = false;

  function emit(path, ls, le, data) {
    const lineLen = le - ls;
    const need = (multi ? Buffer.byteLength(path) + 1 : 0) + lineLen + 1;
    ensure(need);
    if (multi) { outLen += out.write(path, outLen, "latin1"); COLON.copy(out, outLen); outLen += 1; }
    data.copy(out, outLen, ls, le); outLen += lineLen;
    NLB.copy(out, outLen); outLen += 1;
    if (outLen >= FLUSH) flush();
  }

  // Read full file size into rbuf (growing it), starting from `have` bytes already read.
  function readRest(fd, have) {
    let total = have;
    for (;;) {
      if (total === rbuf.length) {
        const nb = Buffer.allocUnsafe(rbuf.length * 2);
        rbuf.copy(nb, 0, 0, total); rbuf = nb;
      }
      const n = readSync(fd, rbuf, total, rbuf.length - total, null);
      if (n === 0) break;
      total += n;
    }
    return total;
  }

  const n = files.length;
  for (;;) {
    const i = Atomics.add(cursor, 0, 1);
    if (i >= n) break;
    const path = files[i];
    let fd;
    try { fd = openSync(path, "r"); } catch { continue; }
    let len = 0;
    try {
      // (b) read a 64KB prefix first
      let got = 0;
      while (got < PEEK_SIZE) {
        const k = readSync(fd, rbuf, got, PEEK_SIZE - got, null);
        if (k === 0) break;
        got += k;
      }
      if (got > 0 && isBinaryPrefix(rbuf, got)) { closeSync(fd); continue; } // binary: rest unread
      // not binary (or short): read the rest only now
      len = readRest(fd, got);
    } finally {
      closeSync(fd);
    }
    if (len === 0) continue;
    if (ci && lowerScratch.length < len) lowerScratch = Buffer.allocUnsafe(len);
    const m = scan(rbuf, len, needle, ci, lowerScratch, path,
      (p, ls, le) => emit(p, ls, le, rbuf));
    if (m) matched = true;
  }
  flush();
  parentPort.postMessage(matched ? 1 : 0);
}

function mainRun() {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);
  if (!args) {
    writeSync(2, "usage: nodegrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n");
    process.exit(2);
  }
  const { pat, paths, ci, r } = args;
  const multi = r || paths.length > 1;

  const files = [];
  collectFiles(paths, r, files);
  if (files.length === 0) process.exit(1);

  let nt = availableParallelism();
  if (nt < 1) nt = 1; if (nt > 16) nt = 16;
  if (nt > files.length) nt = files.length;

  const sab = new SharedArrayBuffer(4);

  let anyMatch = false;
  let done = 0;
  for (let t = 0; t < nt; t++) {
    const w = new Worker(SELF, { workerData: { files, pat, ci, multi, sab } });
    w.on("message", (m) => { if (m) anyMatch = true; });
    w.on("exit", () => { if (++done === nt) process.exit(anyMatch ? 0 : 1); });
  }
}

if (isMainThread) mainRun(); else workerRun();
