// ktgrep_std_mt - idiomatic concurrent Kotlin: collect the file list, then a
// fixed thread pool (one per CPU) pulls file indices off an atomic counter.
// DELIBERATELY allocation-heavy tier: every file gets a FRESH full-size
// ByteArray read IN FULL before the binary (NUL) check.
import java.io.BufferedOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.system.exitProcess

private var pat = ByteArray(0)
private var lpat = ByteArray(0)
private var ci = false
private var recursive = false
private var multi = false

private fun asciiLower(dst: ByteArray, src: ByteArray, n: Int) {
    for (i in 0 until n) {
        val b = src[i]
        dst[i] = if (b >= 'A'.code.toByte() && b <= 'Z'.code.toByte()) (b + 32).toByte() else b
    }
}

private fun indexOf(hay: ByteArray, hayLen: Int, needle: ByteArray, from: Int): Int {
    val n = needle.size
    if (n == 0) return from
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

// Returns true if any match found; appends output bytes into `w`.
private fun searchFile(path: String, w: StringBuilder): Boolean {
    val data: ByteArray = try {
        File(path).readBytes()   // FRESH full ByteArray, read in full
    } catch (e: Exception) {
        return false
    }
    val len = data.size
    val peek = if (len > 65536) 65536 else len
    for (i in 0 until peek) {
        if (data[i] == 0.toByte()) return false // binary
    }
    val hay: ByteArray
    val needle: ByteArray
    if (ci) {
        val lb = ByteArray(len)
        asciiLower(lb, data, len)
        hay = lb
        needle = lpat
    } else {
        hay = data
        needle = pat
    }
    var found = false
    // `pos < len` (not `<=`): with `<=`, an empty needle emits a spurious blank
    // match past the trailing newline. grep -F: empty pattern == one match per
    // line. A non-empty needle can never match at pos==len.
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
        found = true
        if (multi) {
            w.append(path)
            w.append(':')
        }
        // ISO-8859-1: each byte -> one char, preserving byte offsets.
        for (k in ls until le) w.append((data[k].toInt() and 0xFF).toChar())
        w.append('\n')
        pos = le + 1
    }
    return found
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
            val stack = ArrayDeque<File>()
            stack.addLast(f)
            while (stack.isNotEmpty()) {
                val d = stack.removeLast()
                val kids = d.listFiles() ?: continue
                for (k in kids) {
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

    val files = ArrayList<String>()
    for (p in paths) collect(p, files)

    val out = BufferedOutputStream(System.out, 1 shl 16)
    val lock = Object()
    val idx = AtomicInteger(0)
    val nthreads = Runtime.getRuntime().availableProcessors()
    val workers = ArrayList<Thread>(nthreads)
    val matchFlag = booleanArrayOf(false) // mutable shared flag under no contention concern
    for (t in 0 until nthreads) {
        workers.add(thread(start = true) {
            val w = StringBuilder()
            while (true) {
                val i = idx.getAndIncrement()
                if (i >= files.size) break
                w.setLength(0)
                if (searchFile(files[i], w)) matchFlag[0] = true
                if (w.isNotEmpty()) {
                    val bytes = w.toString().toByteArray(Charsets.ISO_8859_1)
                    synchronized(lock) { out.write(bytes) }
                }
            }
        })
    }
    for (wkr in workers) wkr.join()
    out.flush()
    exitProcess(if (matchFlag[0]) 0 else 1)
}
