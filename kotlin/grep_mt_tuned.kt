// ktgrep_std_mt_tuned - concurrent Kotlin, memory-tuned. Each worker thread
// reuses ONE growable read buffer (and one lowercase buffer) across files.
// Reads only a 64 KB prefix first, does the NUL binary-check on that prefix,
// and reads the rest of the file only if it passed. Workers pull file indices
// off an atomic counter; each file's output block is written under a lock.
import java.io.BufferedOutputStream
import java.io.File
import java.io.RandomAccessFile
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

// Per-worker reusable scratch buffers.
private class Scratch {
    var rbuf = ByteArray(65536)   // growable read buffer, reused across files
    var lowbuf = ByteArray(0)     // growable lowercase buffer, reused across files
}

private fun growKeep(buf: ByteArray, need: Int, keep: Int): ByteArray {
    if (buf.size >= need) return buf
    val nb = ByteArray(need)
    System.arraycopy(buf, 0, nb, 0, keep)
    return nb
}

// Returns true if any match found; appends output bytes into `w`.
private fun searchFile(path: String, w: StringBuilder, s: Scratch): Boolean {
    val raf = try {
        RandomAccessFile(path, "r")
    } catch (e: Exception) {
        return false
    }
    try {
        val sizeL = raf.length()
        if (sizeL <= 0L) return false
        val size = if (sizeL > Int.MAX_VALUE) Int.MAX_VALUE else sizeL.toInt()
        val peek = if (size > 65536) 65536 else size

        if (s.rbuf.size < peek) s.rbuf = growKeep(s.rbuf, peek, 0)
        raf.readFully(s.rbuf, 0, peek)

        for (i in 0 until peek) {
            if (s.rbuf[i] == 0.toByte()) return false // binary: rest unread
        }

        if (size > peek) {
            s.rbuf = growKeep(s.rbuf, size, peek) // grow but preserve the prefix
            raf.readFully(s.rbuf, peek, size - peek)
        }
        val data = s.rbuf
        val len = size

        val hay: ByteArray
        val needle: ByteArray
        if (ci) {
            if (s.lowbuf.size < len) s.lowbuf = ByteArray(len)
            asciiLower(s.lowbuf, data, len)
            hay = s.lowbuf
            needle = lpat
        } else {
            hay = data
            needle = pat
        }

        var found = false
        // `pos < len` (not `<=`): with `<=`, an empty needle emits a spurious
        // blank match past the trailing newline. grep -F: empty pattern == one
        // match per line. A non-empty needle can never match at pos==len.
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
            for (k in ls until le) w.append((data[k].toInt() and 0xFF).toChar())
            w.append('\n')
            pos = le + 1
        }
        return found
    } catch (e: Exception) {
        return false
    } finally {
        try { raf.close() } catch (e: Exception) {}
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
    val matchFlag = booleanArrayOf(false)
    for (t in 0 until nthreads) {
        workers.add(thread(start = true) {
            val w = StringBuilder()
            val s = Scratch()
            while (true) {
                val i = idx.getAndIncrement()
                if (i >= files.size) break
                w.setLength(0)
                if (searchFile(files[i], w, s)) matchFlag[0] = true
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
