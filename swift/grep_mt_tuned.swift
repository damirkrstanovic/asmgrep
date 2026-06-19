// swiftgrep_std_mt_tuned - multithreaded + the memory pillar applied. A fixed
// pool of N worker threads each pulls files from a shared atomic index and
// REUSES one growable read buffer (+ one lowercase buffer, one output buffer)
// across every file it processes. Reads a 64 KB prefix first, NUL-checks it, and
// reads the rest only if the prefix passed (so a huge binary is never faulted
// in then discarded). Swift Array<UInt8> is a mutable value type, so a worker
// owning its own [UInt8] and only growing it gives genuine reuse under ARC/CoW
// (no other reference => no copy on mutation). Mirrors d/grep_mt_tuned.d.
#if canImport(Glibc)
import Glibc
#endif

let PREFIX = 65536

var pat: [UInt8] = []
var lpat: [UInt8] = []
var ci = false
var recursive = false
var multi = false
var matched = Int32(0)

var files: [String] = []
var nextIdx = Int(0)
var idxLock = pthread_mutex_t()
var outLock = pthread_mutex_t()

@inline(__always)
func asciiLower(_ dst: inout [UInt8], _ src: UnsafePointer<UInt8>, _ n: Int) {
    dst.withUnsafeMutableBufferPointer { d in
        for i in 0..<n {
            let b = src[i]
            d[i] = (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
        }
    }
}

@inline(__always)
func byteIndex(_ hay: UnsafePointer<UInt8>, _ len: Int,
               _ needle: UnsafePointer<UInt8>, _ nlen: Int, _ from: Int) -> Int {
    if nlen == 0 { return from }
    if from + nlen > len { return -1 }
    guard let h = memmem(hay + from, len - from, needle, nlen) else { return -1 }
    return UnsafePointer(h.assumingMemoryBound(to: UInt8.self)) - hay
}

@inline(__always)
func lineStart(_ data: UnsafePointer<UInt8>, _ m: Int) -> Int {
    var i = m - 1
    while i >= 0 { if data[i] == 0x0A { return i + 1 }; i -= 1 }
    return 0
}

@inline(__always)
func lineEnd(_ data: UnsafePointer<UInt8>, _ m: Int, _ len: Int) -> Int {
    var i = m
    while i < len { if data[i] == 0x0A { return i }; i += 1 }
    return len
}

// Per-thread reusable scratch: each worker owns these (real reuse across every
// file the thread processes). class so it can be passed by reference into the
// worker without value-copying the backing storage.
final class Scratch {
    var data = [UInt8]()  // reused read buffer
    var low = [UInt8]()   // reused lowercase buffer
    var ob = [UInt8]()    // reused output buffer
}

func searchFile(_ s: Scratch, _ path: String) {
    let fd = open(path, O_RDONLY)
    if fd < 0 { return }
    var st = stat()
    if fstat(fd, &st) != 0 { close(fd); return }
    var len = st.st_size > 0 ? Int(st.st_size) : 0
    if s.data.count < len { s.data = [UInt8](repeating: 0, count: len) }

    // Read only the 64 KB prefix first.
    var peek = len < PREFIX ? len : PREFIX
    var off = 0
    while off < peek {
        let got = s.data.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress! + off, peek - off) }
        if got <= 0 { break }
        off += got
    }
    if off < peek { peek = off; len = off }

    // NUL-check the prefix; only read the rest if it passes.
    if peek > 0 {
        let bin = s.data.withUnsafeBufferPointer { memchr($0.baseAddress!, 0, peek) != nil }
        if bin { close(fd); return }   // binary: skip, rest unread
    }

    // Read the remainder.
    while off < len {
        let got = s.data.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress! + off, len - off) }
        if got <= 0 { break }
        off += got
    }
    close(fd)
    if off < len { len = off }
    if len == 0 { return }

    if ci {
        if s.low.count < len { s.low = [UInt8](repeating: 0, count: len) }
        s.data.withUnsafeBufferPointer { asciiLower(&s.low, $0.baseAddress!, len) }
    }

    let pathBytes = Array(path.utf8)
    s.ob.removeAll(keepingCapacity: true)

    s.data.withUnsafeBufferPointer { db in
        let dptr = db.baseAddress!
        let hayArr = ci ? s.low : s.data
        hayArr.withUnsafeBufferPointer { hb in
            let hay = hb.baseAddress!
            let needle = ci ? lpat : pat
            needle.withUnsafeBufferPointer { nb in
                let nptr = nb.baseAddress!
                let nlen = needle.count
                var pos = 0
                while pos < len {
                    let m = byteIndex(hay, len, nptr, nlen, pos)
                    if m < 0 { break }
                    let ls = lineStart(dptr, m)
                    let le = lineEnd(dptr, m, len)
                    matched = 1
                    if multi { s.ob.append(contentsOf: pathBytes); s.ob.append(0x3A) }
                    if le > ls { s.ob.append(contentsOf: UnsafeBufferPointer(start: dptr + ls, count: le - ls)) }
                    s.ob.append(0x0A)
                    pos = le + 1
                }
            }
        }
    }

    if !s.ob.isEmpty {
        pthread_mutex_lock(&outLock)
        s.ob.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count) }
        pthread_mutex_unlock(&outLock)
    }
}

func workerBody() {
    let s = Scratch()
    while true {
        pthread_mutex_lock(&idxLock)
        let i = nextIdx
        nextIdx += 1
        pthread_mutex_unlock(&idxLock)
        if i >= files.count { break }
        searchFile(s, files[i])
    }
}

// pthread entrypoint trampoline (C ABI). No per-thread argument needed; all
// state is global, the work queue is the shared atomic index.
func threadTrampoline(_ arg: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    workerBody()
    return nil
}

func walkDir(_ dir: String) {
    guard let pd = opendir(dir) else { return }
    while let ent = readdir(pd) {
        var nameBuf = ent.pointee.d_name
        let name = withUnsafePointer(to: &nameBuf) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        collect(dir + "/" + name)
    }
    closedir(pd)
}

func collect(_ path: String) {
    var st = stat()
    if lstat(path, &st) != 0 { return }
    let mode = st.st_mode & S_IFMT
    if mode == S_IFLNK { return }
    if mode == S_IFDIR {
        if recursive { walkDir(path) }
    } else if mode == S_IFREG {
        files.append(path)
    }
}

func usage() {
    let b = Array("usage: swiftgrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n".utf8)
    b.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, $0.count) }
    exit(2)
}

func numThreads() -> Int {
    var n = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
    if n < 1 { n = 1 }
    if n > 16 { n = 16 }
    return n
}

func run() {
    var patStr = ""
    var patSet = false
    var paths: [String] = []
    var noMore = false
    for a in CommandLine.arguments[1...] {
        let ab = Array(a.utf8)
        if !noMore && ab.count >= 2 && ab[0] == 0x2D {
            if a == "--" { noMore = true; continue }
            for c in ab[1...] {
                if c == 0x69 { ci = true }
                else if c == 0x72 { recursive = true }
                else { usage() }
            }
        } else if !patSet { patStr = a; patSet = true }
        else { paths.append(a) }
    }
    if !patSet || paths.isEmpty { usage() }

    pat = Array(patStr.utf8)
    lpat = [UInt8](repeating: 0, count: pat.count)
    pat.withUnsafeBufferPointer { asciiLower(&lpat, $0.baseAddress!, pat.count) }
    multi = recursive || paths.count > 1

    for p in paths {
        var st = stat()
        if lstat(p, &st) != 0 { continue }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFDIR {
            if recursive { walkDir(p) }
        } else if mode == S_IFREG {
            files.append(p)
        } else if mode == S_IFLNK {
            if stat(p, &st) == 0 {
                let m2 = st.st_mode & S_IFMT
                if m2 == S_IFREG { files.append(p) }
                else if m2 == S_IFDIR && recursive { walkDir(p) }
            }
        }
    }

    pthread_mutex_init(&idxLock, nil)
    pthread_mutex_init(&outLock, nil)

    if !files.isEmpty {
        var nt = numThreads()
        if nt > files.count { nt = files.count }
        if nt < 1 { nt = 1 }
        var tids = [pthread_t](repeating: pthread_t(), count: nt)
        for t in 0..<nt {
            pthread_create(&tids[t], nil, threadTrampoline, nil)
        }
        for t in 0..<nt {
            pthread_join(tids[t], nil)
        }
    }

    exit(matched != 0 ? 0 : 1)
}

run()
