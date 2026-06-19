// nodegrep_std - idiomatic single-threaded JS grep.
//   Recursive walk via opendirSync/readSync (skip symlinks, don't follow);
//   readFileSync -> Buffer; Buffer.indexOf(needle) scan; NUL-in-first-64KB skip.
//   Output batched into one growing Buffer, written to stdout in chunks.
// Runs unchanged under node, bun, and deno.

import { readFileSync, writeSync } from "node:fs";
import {
  parseArgs, lowerPattern, scan, isBinaryPrefix, collectFiles,
} from "./grep_core.mjs";

function main() {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);
  if (!args) {
    writeSync(2, "usage: nodegrep_std [-r] [-i] PATTERN PATH...\n");
    process.exit(2);
  }
  const { pat, paths, ci, r } = args;
  const patBuf = Buffer.from(pat, "latin1");
  const needle = ci ? lowerPattern(patBuf) : patBuf;
  const multi = r || paths.length > 1;

  const files = [];
  collectFiles(paths, r, files);

  // Output buffering: accumulate into a growing Buffer, flush in chunks.
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
  function flush() {
    if (outLen) { writeSync(1, out, 0, outLen); outLen = 0; }
  }

  let lowerScratch = Buffer.allocUnsafe(0);

  function emit(path, ls, le, data) {
    const lineLen = le - ls;
    const need = (multi ? Buffer.byteLength(path) + 1 : 0) + lineLen + 1;
    ensure(need);
    if (multi) {
      outLen += out.write(path, outLen, "latin1");
      COLON.copy(out, outLen); outLen += 1;
    }
    data.copy(out, outLen, ls, le); outLen += lineLen;
    NLB.copy(out, outLen); outLen += 1;
    if (outLen >= FLUSH) flush();
  }

  let matched = false;
  for (const path of files) {
    let data;
    try { data = readFileSync(path); } catch { continue; }
    const len = data.length;
    if (len === 0) continue;
    if (isBinaryPrefix(data, len)) continue;     // binary skip
    if (ci && lowerScratch.length < len) lowerScratch = Buffer.allocUnsafe(len);
    const m = scan(data, len, needle, ci, lowerScratch, path,
      (p, ls, le) => emit(p, ls, le, data));
    if (m) matched = true;
  }
  flush();
  process.exit(matched ? 0 : 1);
}

main();
