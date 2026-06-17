// ktgrep_std - idiomatic single-threaded Kotlin: walk the filesystem, read each
// file fully into a ByteArray, NUL-check the 64 KB prefix, scan with ByteArray
// indexOf. ASCII-only case folding (byte-exact, matches grep -iF).
import java.io.BufferedOutputStream
import java.io.File
import kotlin.system.exitProcess

private var pat = ByteArray(0)
private var lpat = ByteArray(0)
private var ci = false
private var recursive = false
private var multi = false
private var matched = false
private lateinit var out: BufferedOutputStream
private var lowbuf = ByteArray(0)

// ASCII-only, length-preserving lowercase.
private fun asciiLower(dst: ByteArray, src: ByteArray, n: Int) {
    for (i in 0 until n) {
        val b = src[i]
        dst[i] = if (b >= 'A'.code.toByte() && b <= 'Z'.code.toByte()) (b + 32).toByte() else b
    }
}

// Index of `needle` in hay[from .. hayLen), byte-exact, like bytes.Index.
private fun indexOf(hay: ByteArray, hayLen: Int, needle: ByteArray, from: Int): Int {
    val n = needle.size
    if (n == 0) return from                 // empty needle: matches at `from` (Go semantics)
    if (from + n > hayLen) return -1
    val first = needle[0]
    var i = from
    val last = hayLen - n
    while (i <= last) {
        if (hay[i] == first) {
            var j = 1
            while (j < n && hay[i + j] == needle[j]) j++
            if (j == n) return i
        }
        i++
    }
    return -1
}

private fun lastNl(data: ByteArray, end: Int): Int {
    var i = end - 1
    while (i >= 0) {
        if (data[i] == '\n'.code.toByte()) return i + 1
        i--
    }
    return 0
}

private fun searchFile(path: String) {
    val data: ByteArray = try {
        File(path).readBytes()
    } catch (e: Exception) {
        return
    }
    val len = data.size
    val peek = if (len > 65536) 65536 else len
    for (i in 0 until peek) {
        if (data[i] == 0.toByte()) return // binary
    }
    val hay: ByteArray
    val needle: ByteArray
    if (ci) {
        if (lowbuf.size < len) lowbuf = ByteArray(len)
        asciiLower(lowbuf, data, len)
        hay = lowbuf
        needle = lpat
    } else {
        hay = data
        needle = pat
    }
    // Guard is `pos < len` (not `<=`): with `<=`, an empty needle would emit one
    // spurious blank match past the file's final newline. grep -F treats a
    // trailing '\n' as terminating the last line, so empty pattern == one match
    // per line exactly. A non-empty needle can never match at pos==len anyway.
    var pos = 0
    while (pos < len) {
        val m = indexOf(hay, len, needle, pos)
        if (m < 0) break
        val ls = lastNl(data, m)
        var le = len
        var j = m
        while (j < len) {
            if (data[j] == '\n'.code.toByte()) { le = j; break }
            j++
        }
        matched = true
        if (multi) {
            out.write(path.toByteArray(Charsets.ISO_8859_1))
            out.write(':'.code)
        }
        out.write(data, ls, le - ls)
        out.write('\n'.code)
        pos = le + 1
    }
}

private fun usage(): Nothing {
    System.err.print("usage: ktgrep [-r] [-i] PATTERN PATH...\n")
    exitProcess(2)
}

private fun collect(p: String, files: MutableList<String>) {
    val f = File(p)
    if (!f.exists()) return
    if (f.isDirectory) {
        if (recursive) {
            // Walk without following symlinks; regular files only.
            val stack = ArrayDeque<File>()
            stack.addLast(f)
            while (stack.isNotEmpty()) {
                val d = stack.removeLast()
                val kids = d.listFiles() ?: continue
                for (k in kids) {
                    // listFiles doesn't follow symlink dirs into them unless we recurse;
                    // skip symlinks explicitly.
                    val isSymlink = try {
                        k.canonicalFile != k.absoluteFile
                    } catch (e: Exception) { false }
                    if (isSymlink) continue
                    if (k.isDirectory) stack.addLast(k)
                    else if (k.isFile) files.add(k.path)
                }
            }
        }
    } else if (f.isFile) {
        files.add(p)
    }
}

fun main(args: Array<String>) {
    val paths = ArrayList<String>()
    var patSet = false
    var noMore = false
    for (a in args) {
        if (!noMore && a.length >= 2 && a[0] == '-') {
            if (a == "--") { noMore = true; continue }
            for (idx in 1 until a.length) {
                when (a[idx]) {
                    'i' -> ci = true
                    'r' -> recursive = true
                    else -> usage()
                }
            }
        } else if (!patSet) {
            pat = a.toByteArray(Charsets.ISO_8859_1)
            patSet = true
        } else {
            paths.add(a)
        }
    }
    if (!patSet || paths.isEmpty()) usage()
    lpat = ByteArray(pat.size)
    asciiLower(lpat, pat, pat.size)
    multi = recursive || paths.size > 1
    out = BufferedOutputStream(System.out, 1 shl 16)

    val files = ArrayList<String>()
    for (p in paths) collect(p, files)
    for (fp in files) searchFile(fp)

    out.flush()
    exitProcess(if (matched) 0 else 1)
}
