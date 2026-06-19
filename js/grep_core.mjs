// Shared core for the JS grep variants. Literal (fixed-string) substring search,
// mirroring c/grep_std.c semantics exactly:
//   - -r recurse (skip symlinks, don't follow), -i ASCII case-insensitive, -- ends opts
//   - binary skip: NUL byte in first 64KB -> skip file (grep -I)
//   - output: "path:line\n" when recursive/multiple files, else "line\n"
//   - matching line printed once, scan continues past it
//   - exit: 0=match, 1=no match, 2=usage error
//
// Designed to run UNCHANGED under node, bun, and deno (node: specifiers work on all 3).

import { lstatSync, opendirSync } from "node:fs";

const PEEK = 65536; // 64 KB binary-check prefix
const NL = 0x0a;

// Parse argv (excluding runtime + script). Returns {pat, paths, ci, r} or null on usage error.
export function parseArgs(argv) {
  const paths = [];
  let pat = null;
  let ci = false, r = false, noMore = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!noMore && a.length > 1 && a.charCodeAt(0) === 0x2d /* '-' */) {
      if (a === "--") { noMore = true; continue; }
      for (let k = 1; k < a.length; k++) {
        const c = a[k];
        if (c === "i") ci = true;
        else if (c === "r") r = true;
        else return null;
      }
    } else if (pat === null) {
      pat = a;
    } else {
      paths.push(a);
    }
  }
  if (pat === null || paths.length === 0) return null;
  return { pat, paths, ci, r };
}

// ASCII-lowercase a byte (A-Z only).
function lowerByte(b) {
  return (b >= 0x41 && b <= 0x5a) ? b + 0x20 : b;
}

// Build the lowercased needle Buffer for -i.
export function lowerPattern(patBuf) {
  const out = Buffer.allocUnsafe(patBuf.length);
  for (let i = 0; i < patBuf.length; i++) out[i] = lowerByte(patBuf[i]);
  return out;
}

// In-place ASCII-lowercase a region [0, len) of buf.
function lowerInPlace(buf, len) {
  for (let i = 0; i < len; i++) {
    const b = buf[i];
    if (b >= 0x41 && b <= 0x5a) buf[i] = b + 0x20;
  }
}

// Scan `data` (Buffer, valid bytes [0,len)) for `needle`.
//   - ci: case-insensitive. `lowerScratch` (a Buffer >= len) holds the lowercased
//     copy used as the haystack; `needle` must already be lowercased by the caller.
//   - emit(path, lineStart, lineEnd): called once per matching line (byte range of
//     ORIGINAL data, not the lowercased copy).
// Returns true if any match was found.
export function scan(data, len, needle, ci, lowerScratch, path, emit) {
  let hay = data;
  if (ci) {
    // copy [0,len) into scratch then lowercase it; search the scratch, slice the original
    data.copy(lowerScratch, 0, 0, len);
    lowerInPlace(lowerScratch, len);
    hay = lowerScratch;
  }
  const plen = needle.length;
  let matched = false;
  let pos = 0;
  while (pos <= len) {
    const m = hay.indexOf(needle, pos);
    if (m < 0 || m >= len) break;
    // line bounds in the ORIGINAL data
    let ls = m; while (ls > 0 && data[ls - 1] !== NL) ls--;
    let le = m; while (le < len && data[le] !== NL) le++;
    matched = true;
    emit(path, ls, le);
    pos = le + 1;
    void plen;
  }
  return matched;
}

// Is the first min(len,64KB) bytes binary (contains NUL)?
export function isBinaryPrefix(buf, len) {
  const peek = len < PEEK ? len : PEEK;
  const z = buf.indexOf(0, 0);
  return z >= 0 && z < peek;
}

// Recursively collect regular files under the given path roots into `out` (array of
// path strings). Mirrors nftw(FTW_PHYS): skip symlinks, don't follow them.
export function collectFiles(paths, recurse, out) {
  for (const p of paths) {
    let st;
    try { st = lstatSync(p); } catch { continue; }
    if (st.isDirectory()) {
      if (recurse) walkDir(p, out);
    } else if (st.isFile()) {
      out.push(p);
    }
    // symlink / other as a top-level arg: grep -F follows a symlink given explicitly,
    // but our roots are dirs/files in practice; lstat keeps recursion from following.
  }
}

function walkDir(dir, out) {
  let d;
  try { d = opendirSync(dir); } catch { return; }
  try {
    let ent;
    while ((ent = d.readSync()) !== null) {
      const full = dir.endsWith("/") ? dir + ent.name : dir + "/" + ent.name;
      if (ent.isSymbolicLink()) continue;        // don't follow symlinks
      if (ent.isDirectory()) walkDir(full, out);
      else if (ent.isFile()) out.push(full);
    }
  } finally {
    d.closeSync();
  }
}

export const PEEK_SIZE = PEEK;
