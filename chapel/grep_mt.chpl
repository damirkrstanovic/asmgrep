// chplgrep_std_mt - idiomatic Chapel, DATA-PARALLEL.
//   `forall f in fileList do scan(f)`: the parallel-for is a language
//   primitive -- the qthreads runtime spreads files across all cores.
//   Fresh per-file read (naive allocation), one result bytes per file,
//   written out sequentially at the end (no interleaving).
//   Build: chpl --fast -o bin/chplgrep_std_mt chapel/grep_mt.chpl
use IO, FileSystem, List;

var gPat: bytes;
var gPatLen: int;
var gCI = false, gR = false, gMulti = false;
var gMatched: atomic bool;

proc isBinary(const ref data: bytes, n: int): bool {
  const peek = min(n, 65536);
  for i in 0..<peek do
    if data.byte(i) == 0 then return true;
  return false;
}

proc scanBuf(const ref data: bytes, const ref hay: bytes, n: int,
             const ref path: bytes, ref outb: bytes) {
  if n == 0 then return;
  if gPatLen == 0 {
    var ls = 0;
    while ls < n {
      var le = ls;
      while le < n && data.byte(le) != 0x0A do le += 1;
      gMatched.write(true);
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
    gMatched.write(true);
    if gMulti { outb += path; outb += b":"; }
    outb += data[ls..<le];
    outb += b"\n";
    pos = le + 1;
  }
}

// returns this file's output bytes (empty if no match / binary / unreadable)
proc searchFile(const ref path: string): bytes {
  var outb: bytes;
  try {
    const f = open(path, ioMode.r);
    const sz = f.size;
    if sz <= 0 { f.close(); return outb; }
    const r = f.reader(locking=false);
    var data: bytes;
    r.readAll(data);
    r.close(); f.close();
    const n = data.size;
    if isBinary(data, n) then return outb;
    const pb = path: bytes;
    if gCI {
      const low = data.toLower();
      scanBuf(data, low, n, pb, outb);
    } else {
      scanBuf(data, data, n, pb, outb);
    }
  } catch { }
  return outb;
}

proc usage(): int {
  stderr.writeln("usage: chplgrep_std_mt [-r] [-i] PATTERN PATH...");
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
  gMatched.write(false);

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

  const nf = files.size;
  const fileArr = files.toArray();
  var results: [0..<nf] bytes;

  // THE PRIMITIVE: data-parallel for. qthreads schedules the iterations
  // across all cores; each file's result is independent.
  forall i in 0..<nf do
    results[i] = searchFile(fileArr[i]);

  // sequential write-out: no interleaving, order stable.
  for i in 0..<nf do
    if results[i].size > 0 then stdout.writeBinary(results[i]);
  stdout.flush();
  return if gMatched.read() then 0 else 1;
}
