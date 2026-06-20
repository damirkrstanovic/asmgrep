# nimgrep_std_mt - naive parallelism with Nim's idiomatic concurrency: collect
# the file list, then a fixed pool of raw Thread workers (createThread) pulls
# files off a shared atomic index. NO memory pillar: each file is read FRESH into
# a new seq (naive per-file allocation). Output serialized with a Lock around
# whole-line writes. Mirrors c/grep_std_mt.c.
#   nim c -d:release --threads:on -o:bin/nimgrep_std_mt nim/grep_mt.nim
import std/[os, posix, locks, atomics, cpuinfo]

const Prefix = 65536

var
  pat {.global.}: seq[byte]
  lpat {.global.}: seq[byte]
  ci {.global.} = false
  recursive {.global.} = false
  multi {.global.} = false
  files {.global.}: seq[string]
  nextIdx {.global.}: Atomic[int]
  matched {.global.}: Atomic[int]
  outLock {.global.}: Lock

template lowerByte(b: byte): byte =
  (if b >= byte('A') and b <= byte('Z'): byte(b + 32) else: b)

proc byteIndex(hay: openArray[byte], needle: openArray[byte], frm: int): int =
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

proc searchFile(path: string, ob: var string) =
  var f: File
  if not open(f, path, fmRead): return
  let szl = getFileSize(f)
  if szl <= 0: (close(f); return)
  let sz = int(szl)
  var data = newSeq[byte](sz)          # fresh allocation per file (naive)
  let got = readBuffer(f, addr data[0], sz)
  close(f)
  let rd = if got < sz: got else: sz
  if rd <= 0: return

  let peek = if rd < Prefix: rd else: Prefix
  for i in 0 ..< peek:
    if data[i] == 0'u8: return         # binary skip

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
    matched.store(1, moRelaxed)
    if multi:
      for b in pathBytes: ob.add char(b)
      ob.add ':'
    for k in ls ..< le: ob.add char(data[k])
    ob.add '\n'
    pos = le + 1

proc worker(unused: int) {.thread.} =
  # ORC threads share one heap, so reading the immutable `files`/`pat` globals
  # across threads is safe; the compiler is conservative, so assert gcsafe.
  {.cast(gcsafe).}:
    var ob = newStringOfCap(65536)
    while true:
      let idx = nextIdx.fetchAdd(1, moRelaxed)
      if idx >= files.len: break
      searchFile(files[idx], ob)
    if ob.len > 0:
      acquire(outLock)
      discard writeBuffer(stdout, addr ob[0], ob.len)
      release(outLock)

proc isSymlink(path: string): bool =
  var st: Stat
  if lstat(path.cstring, st) != 0: return false
  S_ISLNK(st.st_mode)

proc walk(dir: string) =
  for kind, p in walkDir(dir):
    case kind
    of pcFile: files.add p
    of pcDir:
      if not isSymlink(p): walk(p)
    of pcLinkToFile, pcLinkToDir: discard

proc usage() =
  stderr.write "usage: nimgrep_std_mt [-r] [-i] PATTERN PATH...\n"
  quit(2)

proc numThreads(): int =
  result = countProcessors()
  if result < 1: result = 6
  if result > 16: result = 16

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

  for p in paths:
    var st: Stat
    if stat(p.cstring, st) != 0: continue
    if S_ISDIR(st.st_mode):
      if recursive: walk(p)
    elif S_ISREG(st.st_mode):
      files.add p

  nextIdx.store(0)
  matched.store(0)
  initLock(outLock)

  var nt = numThreads()
  if nt > files.len: nt = files.len
  if nt < 1: nt = 1

  if files.len > 0:
    var threads = newSeq[Thread[int]](nt)
    for i in 0 ..< nt: createThread(threads[i], worker, i)
    joinThreads(threads)

  stdout.flushFile()
  quit(if matched.load() != 0: 0 else: 1)

main()
