// chplgrep_std - idiomatic Chapel, SERIAL baseline.
//   A plain `for` loop over the file list (NOT forall): the sequential
//   reference shape, whole-file read + bytes.find(), one core only.
//   Build: chpl --fast -o bin/chplgrep_std chapel/grep_std.chpl
use IO, FileSystem, List, CTypes;

config const dummy = 0; // keep config machinery quiet; real args parsed by hand

var gPat: bytes;        // the literal needle (already folded if -i)
var gPatLen: int;
var gCI = false, gR = false, gMulti = false;
var gMatched = false;

// NUL in the first 64 KiB => treat as binary, skip (grep -I).
proc isBinary(const ref data: bytes, n: int): bool {
  const peek = min(n, 65536);
  for i in 0..<peek do
    if data.byte(i) == 0 then return true;
  return false;
}

// Scan one already-loaded buffer and print matching lines (path: prefix when
// gMulti). `data` is the raw bytes; `hay` is the search haystack (== data, or a
// lowercased copy when -i). Mirrors c/grep_std.c exactly.
proc scanBuf(const ref data: bytes, const ref hay: bytes, n: int,
             const ref path: bytes, ref outb: bytes) {
  if n == 0 then return;
  if gPatLen == 0 {
    // empty pattern: every line matches (grep -F "" prints the whole file).
    var ls = 0;
    while ls < n {
      var le = ls;
      while le < n && data.byte(le) != 0x0A do le += 1;
      gMatched = true;
      if gMulti { outb += path; outb += b":"; }
      outb += data[ls..<le];
      outb += b"\n";
      ls = le + 1;
    }
    return;
  }
  var pos = 0;
  while pos < n {
    const m = hay.find(gPat, pos..<n);
    if m == -1 then break;
    var ls = m;
    while ls > 0 && data.byte(ls-1) != 0x0A do ls -= 1;
    var le = m;
    while le < n && data.byte(le) != 0x0A do le += 1;
    gMatched = true;
    if gMulti { outb += path; outb += b":"; }
    outb += data[ls..<le];
    outb += b"\n";
    pos = le + 1;
  }
}

proc searchFile(const ref path: string, ref outb: bytes) {
  try {
    const f = open(path, ioMode.r);
    const sz = f.size;
    if sz <= 0 { f.close(); return; }
    const r = f.reader(locking=false);
    var data: bytes;
    r.readAll(data);
    r.close(); f.close();
    const n = data.size;
    if isBinary(data, n) then return;
    const pb = path: bytes;
    if gCI {
      const low = data.toLower();
      scanBuf(data, low, n, pb, outb);
    } else {
      scanBuf(data, data, n, pb, outb);
    }
  } catch { /* unreadable file: skip, like grep */ }
}

proc usage(): int {
  stderr.writeln("usage: chplgrep_std [-r] [-i] PATTERN PATH...");
  return 2;
}

proc main(args: [] string): int {
  var paths: list(string);
  var pat: string;
  var havePat = false;
  var noMore = false;
  for i in 1..<args.size {
    const a = args[i];
    if !noMore && a.size >= 2 && a[0] == "-" {
      if a == "--" { noMore = true; continue; }
      for j in 1..<a.size {
        const c = a[j];
        if c == "i" then gCI = true;
        else if c == "r" then gR = true;
        else return usage();
      }
    } else if !havePat { pat = a; havePat = true; }
    else paths.pushBack(a);
  }
  if !havePat || paths.size == 0 then return usage();

  gPat = pat: bytes;
  if gCI then gPat = gPat.toLower();
  gPatLen = gPat.size;
  gMulti = gR || paths.size > 1;

  // collect the file list (serial walk), then a plain serial `for`.
  var files: list(string);
  for p in paths {
    try {
      if isDir(p) {
        if gR {
          for f in findFiles(p, recursive=true, hidden=true) {
            if !isSymlink(f) then files.pushBack(f);
          }
        }
      } else if isFile(p) {
        files.pushBack(p);
      }
    } catch { }
  }

  var outb: bytes;
  for f in files do
    searchFile(f, outb);

  if outb.size > 0 then stdout.writeBinary(outb);
  stdout.flush();
  return if gMatched then 0 else 1;
}
