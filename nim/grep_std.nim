# nimgrep_std - idiomatic single-threaded Nim: recurse with os.walkDir (skip
# symlinks, don't follow), read the whole file into a seq[byte], literal
# substring search via a byte find, ASCII-only -i fold, NUL-in-first-64KB binary
# skip. Mirrors c/grep_std.c. Batched output to a string flushed at the end.
#   nim c -d:release --threads:on -o:bin/nimgrep_std nim/grep_std.nim
import std/[os, posix]

const Prefix = 65536

var
  pat: seq[byte]
  lpat: seq[byte]
  ci = false
  recursive = false
  multi = false
  matched = false
  outBuf: string

template lowerByte(b: byte): byte =
  (if b >= byte('A') and b <= byte('Z'): byte(b + 32) else: b)

proc byteIndex(hay: openArray[byte], needle: openArray[byte], frm: int): int =
  ## first index >= frm where needle occurs in hay, or -1.
  let nlen = needle.len
  if nlen == 0: return frm
  let hlen = hay.len
  if frm + nlen > hlen: return -1
  let first = needle[0]
  let last = hlen - nlen
  var i = frm
  while i <= last:
    if hay[i] == first:
      var j = 1
      while j < nlen and hay[i + j] == needle[j]: inc j
      if j == nlen: return i
    inc i
  -1

proc searchFile(path: string) =
  var f: File
  if not open(f, path, fmRead): return
  let szl = getFileSize(f)
  if szl <= 0: (close(f); return)
  let sz = int(szl)
  var data = newSeq[byte](sz)
  let got = readBuffer(f, addr data[0], sz)
  close(f)
  let rd = if got < sz: got else: sz
  if rd <= 0: return

  # binary skip: NUL in first 64 KB
  let peek = if rd < Prefix: rd else: Prefix
  for i in 0 ..< peek:
    if data[i] == 0'u8: return

  var low: seq[byte]
  if ci:
    low = newSeq[byte](rd)
    for i in 0 ..< rd: low[i] = lowerByte(data[i])
  let needle = if ci: lpat else: pat

  let pathBytes = cast[seq[byte]](path)
  var pos = 0
  while pos < rd:
    let m =
      if ci: byteIndex(toOpenArray(low, 0, rd - 1), needle, pos)
      else:  byteIndex(toOpenArray(data, 0, rd - 1), needle, pos)
    if m < 0: break
    var ls = m
    while ls > 0 and data[ls - 1] != byte('\n'): dec ls
    var le = m
    while le < rd and data[le] != byte('\n'): inc le
    matched = true
    if multi:
      for b in pathBytes: outBuf.add char(b)
      outBuf.add ':'
    for k in ls ..< le: outBuf.add char(data[k])
    outBuf.add '\n'
    pos = le + 1

proc isSymlink(path: string): bool =
  var st: Stat
  if lstat(path.cstring, st) != 0: return false
  S_ISLNK(st.st_mode)

proc walk(dir: string) =
  for kind, p in walkDir(dir):
    case kind
    of pcFile: searchFile(p)
    of pcDir:
      if not isSymlink(p): walk(p)
    of pcLinkToFile, pcLinkToDir: discard  # skip symlinks (don't follow)

proc usage() =
  stderr.write "usage: nimgrep_std [-r] [-i] PATTERN PATH...\n"
  quit(2)

proc main() =
  var
    patStr = ""
    patSet = false
    paths: seq[string]
    noMore = false
  for a in commandLineParams():
    if not noMore and a.len >= 2 and a[0] == '-':
      if a == "--": noMore = true; continue
      for c in a[1 .. ^1]:
        if c == 'i': ci = true
        elif c == 'r': recursive = true
        else: usage()
    elif not patSet:
      patStr = a; patSet = true
    else:
      paths.add a
  if not patSet or paths.len == 0: usage()

  pat = cast[seq[byte]](patStr)
  lpat = newSeq[byte](pat.len)
  for i in 0 ..< pat.len: lpat[i] = lowerByte(pat[i])
  multi = recursive or paths.len > 1

  outBuf = newStringOfCap(1 shl 20)

  for p in paths:
    var st: Stat
    if stat(p.cstring, st) != 0: continue
    if S_ISDIR(st.st_mode):
      if recursive: walk(p)
    elif S_ISREG(st.st_mode):
      searchFile(p)

  if outBuf.len > 0: stdout.write outBuf
  stdout.flushFile()
  quit(if matched: 0 else: 1)

main()
