// nodegrep_std_mt - idiomatic JS + a worker_threads pool over the collected file
// list. NAIVE allocation: each worker does a fresh readFileSync per file (a new
// Buffer every time). This is the "bolt threads onto allocation-heavy code" variant.
//
// Work is handed out via a shared atomic cursor (SharedArrayBuffer) so workers pull
// the next file index lock-free. Each worker batches whole lines into its own Buffer
// and flushes with a single writeSync (one write() syscall => never splits a line).
//
// worker_threads is a node: API; this file is launched under node (see launchers).

import {
  Worker, isMainThread, workerData, parentPort,
} from "node:worker_threads";
import { readFileSync, writeSync } from "node:fs";
import { availableParallelism } from "node:os";
import { fileURLToPath } from "node:url";
import {
  parseArgs, lowerPattern, scan, isBinaryPrefix, collectFiles,
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

  const n = files.length;
  for (;;) {
    const i = Atomics.add(cursor, 0, 1);
    if (i >= n) break;
    const path = files[i];
    let data;
    try { data = readFileSync(path); } catch { continue; }   // NAIVE: fresh Buffer per file
    const len = data.length;
    if (len === 0) continue;
    if (isBinaryPrefix(data, len)) continue;
    if (ci && lowerScratch.length < len) lowerScratch = Buffer.allocUnsafe(len);
    const m = scan(data, len, needle, ci, lowerScratch, path,
      (p, ls, le) => emit(p, ls, le, data));
    if (m) matched = true;
  }
  flush();
  parentPort.postMessage(matched ? 1 : 0);
}

function mainRun() {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);
  if (!args) {
    writeSync(2, "usage: nodegrep_std_mt [-r] [-i] PATTERN PATH...\n");
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

  const sab = new SharedArrayBuffer(4);  // shared atomic cursor, starts at 0

  let anyMatch = false;
  let done = 0;
  for (let t = 0; t < nt; t++) {
    const w = new Worker(SELF, { workerData: { files, pat, ci, multi, sab } });
    w.on("message", (m) => { if (m) anyMatch = true; });
    w.on("exit", () => {
      if (++done === nt) process.exit(anyMatch ? 0 : 1);
    });
  }
}

if (isMainThread) mainRun(); else workerRun();
