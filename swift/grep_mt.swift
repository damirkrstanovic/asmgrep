// swiftgrep_std_mt - naive parallelism. Collect the file list (single-threaded
// recursive walk), then parallelize with GCD DispatchQueue.concurrentPerform
// over the files. Fresh per-file read (naive allocation, no buffer reuse).
// Output is per-line atomic across workers: each worker builds a local output
// buffer and flushes it under a lock so a flush never splits a line.
// Native LLVM (swiftc -O) + ARC. Mirrors c/grep_std_mt.c (minus the memory pillar).
#if canImport(Glibc)
import Glibc
#endif
import Dispatch

var pat: [UInt8] = []
var lpat: [UInt8] = []
var ci = false
var recursive = false
var multi = false
var matched = Int32(0)  // set under no lock; written 1, read once at the end

var files: [String] = []
let outLock = NSLockShim()

// A tiny pthread_mutex wrapper (Foundation's NSLock works too, but this keeps
// the dependency to Glibc/Dispatch only).
final class NSLockShim {
    private var m = pthread_mutex_t()
    init() { pthread_mutex_init(&m, nil) }
    func lock() { pthread_mutex_lock(&m) }
    func unlock() { pthread_mutex_unlock(&m) }
}

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

func readAll(_ fd: Int32) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 65536)
    var off = 0
    while true {
        if off == buf.count { buf.append(contentsOf: repeatElement(0, count: buf.count)) }
        let got = buf.withUnsafeMutableBufferPointer { b in
            read(fd, b.baseAddress! + off, b.count - off)
        }
        if got <= 0 { break }
        off += got
    }
    buf.removeLast(buf.count - off)
    return buf
}

func searchFile(_ path: String) {
    let fd = open(path, O_RDONLY)
    if fd < 0 { return }
    let data = readAll(fd)           // fresh allocation every file (naive)
    close(fd)
    let len = data.count
    if len == 0 { return }

    let peek = len < 65536 ? len : 65536
    let isBinary = data.withUnsafeBufferPointer { memchr($0.baseAddress!, 0, peek) != nil }
    if isBinary { return }

    var low: [UInt8] = []
    if ci {
        low = [UInt8](repeating: 0, count: len)
        data.withUnsafeBufferPointer { asciiLower(&low, $0.baseAddress!, len) }
    }

    let pathBytes = Array(path.utf8)
    var ob = [UInt8]()
    ob.reserveCapacity(256)

    data.withUnsafeBufferPointer { db in
        let dptr = db.baseAddress!
        let hayArr = ci ? low : data
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
                    if multi { ob.append(contentsOf: pathBytes); ob.append(0x3A) }
                    if le > ls { ob.append(contentsOf: UnsafeBufferPointer(start: dptr + ls, count: le - ls)) }
                    ob.append(0x0A)
                    pos = le + 1
                }
            }
        }
    }

    if !ob.isEmpty {
        outLock.lock()
        ob.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count) }
        outLock.unlock()
    }
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
    let b = Array("usage: swiftgrep_std_mt [-r] [-i] PATTERN PATH...\n".utf8)
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

    if !files.isEmpty {
        // GCD data-parallel loop: one closure invocation per file, spread across
        // the global concurrent queue's worker threads.
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            searchFile(files[i])
        }
    }

    exit(matched != 0 ? 0 : 1)
}

run()
