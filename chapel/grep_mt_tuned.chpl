// chplgrep_std_mt_tuned - idiomatic Chapel, DATA-PARALLEL + the memory pillar.
//   `forall f in fileList with (var outAcc=..., var pref=..., var rest=...)`:
//   the `with (var ...)` TASK INTENT gives each underlying qthreads task its
//   OWN buffers, reused across the files that task handles -- the natural
//   Chapel mapping of the buffer-reuse pillar.
//   Plus the 64 KiB-prefix binary check: read the prefix, test for NUL, and
//   read the rest ONLY if the file isn't binary (so a huge .git pack is
//   checked-and-skipped without faulting the whole thing in).
//   Build: chpl --fast -o bin/chplgrep_std_mt_tuned chapel/grep_mt_tuned.chpl
use IO, FileSystem, List;

param PEEK = 65536;

var gPat: bytes;
var gPatLen: int;
var gCI = false, gR = false, gMulti = false;
var gMatched: atomic bool;

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

// `outAcc`, `pref`, `rest` are TASK-PRIVATE (passed by ref from the `with`
// intent) and reused across every file this task handles.
proc searchFile(const ref path: string, ref outAcc: bytes,
                ref pref: bytes, ref rest: bytes) {
  try {
    const f = open(path, ioMode.r);
    const sz = f.size;
    if sz <= 0 { f.close(); return; }
    const r = f.reader(locking=false);
    // read only the prefix first; decide binary before faulting in the rest.
    const peek = min(sz, PEEK);
    r.readBinary(pref, peek);              // overwrites pref
    const pn = pref.size;
    for i in 0..<pn do
      if pref.byte(i) == 0 { r.close(); f.close(); return; }  // binary: skip
    var data: bytes;
    if sz > pn {
      r.readBinary(rest, sz - pn);         // read the rest only now
      data = pref + rest;
    } else {
      data = pref;
    }
    r.close(); f.close();
    const n = data.size;
    const pb = path: bytes;
    if gCI {
      const low = data.toLower();
      scanBuf(data, low, n, pb, outAcc);
    } else {
      scanBuf(data, data, n, pb, outAcc);
    }
  } catch { }
}

proc usage(): int {
  stderr.writeln("usage: chplgrep_std_mt_tuned [-r] [-i] PATTERN PATH...");
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

  // THE PILLAR MAPPING: data-parallel for with task-private reused buffers.
  // `pref`/`rest` are the read scratch and `outAcc` the per-file emit buffer;
  // all three are `with (var ...)` TASK INTENTS, so each underlying qthreads
  // task gets its OWN copy and reuses it across every file it handles -- the
  // buffer-reuse pillar expressed as a task intent. Per-file output is stashed
  // into `results[i]` so the final write is order-stable and never interleaves.
  forall i in 0..<nf with (var outAcc: bytes, var pref: bytes, var rest: bytes) {
    outAcc = b"";
    searchFile(fileArr[i], outAcc, pref, rest);
    if outAcc.size > 0 then results[i] = outAcc;
  }

  for i in 0..<nf do
    if results[i].size > 0 then stdout.writeBinary(results[i]);
  stdout.flush();
  return if gMatched.read() then 0 else 1;
}
