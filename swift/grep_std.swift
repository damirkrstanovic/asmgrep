// swiftgrep_std - idiomatic single-threaded Swift grep -F clone.
// Native LLVM-compiled (swiftc -O) with ARC (a third memory model: neither
// tracing-GC nor manual malloc/free). Recursive walk via Glibc opendir/readdir
// (skip symlinks, don't follow). Whole-file read. SCAN: byte-oriented via
// Glibc memmem() -- grep -F is a literal byte search, and memmem is the fast
// idiomatic option (Foundation Data.range(of:) would box bytes and is slower).
// ASCII-only -i folding (map A-Z, not Unicode). NUL-in-first-64KB binary skip.
// Mirrors c/grep_std.c semantics.
#if canImport(Glibc)
import Glibc
#endif

var pat: [UInt8] = []
var lpat: [UInt8] = []
var ci = false
var recursive = false
var multi = false
var matched = false

// reused output buffer flushed to fd 1
let OUTCAP = 1 << 16
var outBuf = [UInt8](repeating: 0, count: 1 << 16)
var outLen = 0

@inline(__always)
func flushOut() {
    if outLen > 0 {
        outBuf.withUnsafeBytes { _ = write(1, $0.baseAddress, outLen) }
        outLen = 0
    }
}

func outBytes(_ p: UnsafePointer<UInt8>, _ n: Int) {
    if n == 0 { return }
    if n >= OUTCAP {
        flushOut()
        _ = write(1, p, n)
        return
    }
    if outLen + n > OUTCAP { flushOut() }
    outBuf.withUnsafeMutableBufferPointer { dst in
        _ = memcpy(dst.baseAddress! + outLen, p, n)
    }
    outLen += n
}

@inline(__always)
func outByte(_ b: UInt8) {
    if outLen + 1 > OUTCAP { flushOut() }
    outBuf[outLen] = b
    outLen += 1
}

// ASCII-only, length-preserving lowercase (matches grep -iF).
func asciiLower(_ dst: inout [UInt8], _ src: UnsafePointer<UInt8>, _ n: Int) {
    dst.withUnsafeMutableBufferPointer { d in
        for i in 0..<n {
            let b = src[i]
            d[i] = (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
        }
    }
}

// First index >= from where needle occurs in hay[0..len]; -1 if none.
// Empty needle returns from. Uses memmem (Glibc) for the literal scan.
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
    while i >= 0 {
        if data[i] == 0x0A { return i + 1 }
        i -= 1
    }
    return 0
}

@inline(__always)
func lineEnd(_ data: UnsafePointer<UInt8>, _ m: Int, _ len: Int) -> Int {
    var i = m
    while i < len {
        if data[i] == 0x0A { return i }
        i += 1
    }
    return len
}

var lowbuf: [UInt8] = []  // reused ASCII-lowercase scratch

// Read an entire fd into a growable buffer.
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
    let data = readAll(fd)
    close(fd)
    let len = data.count
    if len == 0 { return }

    let peek = len < 65536 ? len : 65536
    let isBinary = data.withUnsafeBufferPointer { b -> Bool in
        memchr(b.baseAddress!, 0, peek) != nil
    }
    if isBinary { return }

    if ci {
        if lowbuf.count < len { lowbuf = [UInt8](repeating: 0, count: len) }
        data.withUnsafeBufferPointer { b in asciiLower(&lowbuf, b.baseAddress!, len) }
    }

    let pathBytes = Array(path.utf8)
    data.withUnsafeBufferPointer { db in
        let dptr = db.baseAddress!
        let hayArr = ci ? lowbuf : data
        hayArr.withUnsafeBufferPointer { hb in
            let hay = hb.baseAddress!
            let needle = ci ? lpat : pat
            needle.withUnsafeBufferPointer { nb in
                let nptr = nb.baseAddress!
                let nlen = needle.count
                var pos = 0
                // pos < len (not <=): empty needle would otherwise yield a phantom
                // match at pos==len; grep -F "" prints each line once.
                while pos < len {
                    let m = byteIndex(hay, len, nptr, nlen, pos)
                    if m < 0 { break }
                    let ls = lineStart(dptr, m)
                    let le = lineEnd(dptr, m, len)
                    matched = true
                    if multi {
                        pathBytes.withUnsafeBufferPointer { outBytes($0.baseAddress!, $0.count) }
                        outByte(0x3A)
                    }
                    if le > ls { outBytes(dptr + ls, le - ls) }
                    outByte(0x0A)
                    pos = le + 1
                }
            }
        }
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
        visit(dir + "/" + name)
    }
    closedir(pd)
}

func visit(_ path: String) {
    var st = stat()
    if lstat(path, &st) != 0 { return }
    let mode = st.st_mode & S_IFMT
    if mode == S_IFLNK { return }  // never follow symlinks during recursion
    if mode == S_IFDIR {
        if recursive { walkDir(path) }
    } else if mode == S_IFREG {
        searchFile(path)
    }
}

func usage() {
    let msg = "usage: swiftgrep_std [-r] [-i] PATTERN PATH...\n"
    let b = Array(msg.utf8)
    b.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, $0.count) }
    exit(2)
}

func run() {
    var patStr = ""
    var patSet = false
    var paths: [String] = []
    var noMore = false
    let args = CommandLine.arguments
    for a in args[1...] {
        let ab = Array(a.utf8)
        if !noMore && ab.count >= 2 && ab[0] == 0x2D {
            if a == "--" { noMore = true; continue }
            for c in ab[1...] {
                if c == 0x69 { ci = true }          // 'i'
                else if c == 0x72 { recursive = true } // 'r'
                else { usage() }
            }
        } else if !patSet {
            patStr = a
            patSet = true
        } else {
            paths.append(a)
        }
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
            searchFile(p)
        } else if mode == S_IFLNK {
            // top-level symlink arg: resolve once like grep -F does.
            if stat(p, &st) == 0 {
                let m2 = st.st_mode & S_IFMT
                if m2 == S_IFREG { searchFile(p) }
                else if m2 == S_IFDIR && recursive { walkDir(p) }
            }
        }
    }

    flushOut()
    exit(matched ? 0 : 1)
}

run()
