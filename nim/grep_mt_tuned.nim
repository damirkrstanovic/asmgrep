# nimgrep_std_mt_tuned - multithreaded + the memory pillar. Each worker reuses
# ONE growable read buffer (and one lowercase buffer, one output buffer) across
# every file it processes. Reads a 64 KB prefix first, NUL-checks it, and only
# reads the rest of the file if the prefix passed. Output serialized with a Lock
# around whole-buffer writes. Mirrors c/grep_std_mt.c and d/grep_mt_tuned.d.
#   nim c -d:release --threads:on -o:bin/nimgrep_std_mt_tuned nim/grep_mt_tuned.nim
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

proc byteIndex(hay: openArray[byte], len: int, needle: openArray[byte], frm: int): int =
  let nlen = needle.len
  if nlen == 0: return frm
  if frm + nlen > len: return -1
  let first = needle[0]
  let last = len - nlen
  var i = frm
  while i <= last:
    if hay[i] == first:
      var j = 1
      while j < nlen and hay[i + j] == needle[j]: inc j
      if j == nlen: return i
    inc i
  -1

# Per-thread reusable scratch: each worker owns its buffers (real reuse across
# every file the thread processes).
type Scratch = object
  data: seq[byte]   # reused read buffer
  low: seq[byte]    # reused lowercase buffer
  ob: string        # reused output buffer

proc searchFile(s: var Scratch, path: string) =
  let fd = open(path.cstring, O_RDONLY)
  if fd < 0: return
  var st: Stat
  if fstat(fd, st) != 0: (discard close(fd); return)
  var len = if st.st_size > 0: int(st.st_size) else: 0
  if len <= 0: (discard close(fd); return)
  if s.data.len < len: s.data.setLen(len)

  # read only the 64 KB prefix first
  var peek = if len < Prefix: len else: Prefix
  var off = 0
  while off < peek:
    let got = read(fd, addr s.data[off], peek - off)
    if got <= 0: break
    off += got
  if off < peek: (peek = off; len = off)

  # NUL-check the prefix; only read the rest if it passes
  for i in 0 ..< peek:
    if s.data[i] == 0'u8: (discard close(fd); return)   # binary

  # read the remainder
  while off < len:
    let got = read(fd, addr s.data[off], len - off)
    if got <= 0: break
    off += got
  discard close(fd)
  if off < len: len = off
  if len <= 0: return

  let needle = if ci: lpat else: pat
  if ci:
    if s.low.len < len: s.low.setLen(len)
    for i in 0 ..< len: s.low[i] = lowerByte(s.data[i])

  let pathBytes = cast[seq[byte]](path)
  var pos = 0
  while pos < len:
    let m =
      if ci: byteIndex(s.low, len, needle, pos)
      else:  byteIndex(s.data, len, needle, pos)
    if m < 0: break
    var ls = m
    while ls > 0 and s.data[ls - 1] != byte('\n'): dec ls
    var le = m
    while le < len and s.data[le] != byte('\n'): inc le
    matched.store(1, moRelaxed)
    if multi:
      for b in pathBytes: s.ob.add char(b)
      s.ob.add ':'
    for k in ls ..< le: s.ob.add char(s.data[k])
    s.ob.add '\n'
    pos = le + 1

  if s.ob.len > 0:
    acquire(outLock)
    discard writeBuffer(stdout, addr s.ob[0], s.ob.len)
    release(outLock)
    s.ob.setLen(0)

proc worker(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    var s = Scratch(ob: newStringOfCap(65536))
    while true:
      let idx = nextIdx.fetchAdd(1, moRelaxed)
      if idx >= files.len: break
      searchFile(s, files[idx])

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
  stderr.write "usage: nimgrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n"
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
