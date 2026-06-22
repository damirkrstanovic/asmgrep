//> using platform native
//> using nativeMode release-fast
//
// scalagrep_std - native-by-design (LLVM-AOT via Scala Native) literal grep
// clone. The native counterpart to the repo's GraalVM (java/GrepStd) entry.
// Idiomatic single-threaded: NIO Files.readAllBytes + manual byte-array
// substring search (no regex), buffered raw stdout, NUL-in-first-64KB binary
// skip. Mirrors python/grep_std.py byte-for-byte against `grep -F`.

import java.io.{BufferedOutputStream, OutputStream}
import java.nio.file.{Files, Path, Paths, LinkOption}
import java.nio.file.attribute.BasicFileAttributes

object GrepStd {
  var pat: Array[Byte] = Array.emptyByteArray
  var lpat: Array[Byte] = Array.emptyByteArray
  var patSet = false
  var ci = false
  var recursive = false
  var multi = false
  var matched = false
  var out: OutputStream = null
  var lowbuf: Array[Byte] = Array.emptyByteArray // reused ASCII-lowercase scratch

  // ASCII-only, length-preserving lowercase (matches grep -iF).
  def asciiLower(dst: Array[Byte], src: Array[Byte], len: Int): Unit = {
    var i = 0
    while (i < len) {
      val b = src(i)
      if (b >= 'A' && b <= 'Z') dst(i) = (b + 32).toByte else dst(i) = b
      i += 1
    }
  }

  // index of needle in hay[from:len], or -1. Empty needle returns from.
  def indexOf(hay: Array[Byte], len: Int, from: Int, needle: Array[Byte]): Int = {
    val n = needle.length
    if (n == 0) return from
    val end = len - n
    var i = from
    while (i <= end) {
      var j = 0
      while (j < n && hay(i + j) == needle(j)) j += 1
      if (j == n) return i
      i += 1
    }
    -1
  }

  def lastIndexOfNL(data: Array[Byte], m: Int): Int = {
    var i = m - 1
    while (i >= 0) { if (data(i) == '\n') return i; i -= 1 }
    -1
  }

  def indexOfNL(data: Array[Byte], from: Int, len: Int): Int = {
    var i = from
    while (i < len) { if (data(i) == '\n') return i; i += 1 }
    -1
  }

  def searchFile(path: String): Unit = {
    var data: Array[Byte] = null
    try {
      data = Files.readAllBytes(Paths.get(path))
    } catch { case _: Throwable => return }
    val len = data.length
    if (len == 0) return
    val peek = math.min(len, 65536)
    var i = 0
    while (i < peek) { if (data(i) == 0) return; i += 1 } // binary skip

    var hay = data
    var needle = pat
    if (ci) {
      if (lowbuf.length < len) lowbuf = new Array[Byte](len)
      asciiLower(lowbuf, data, len)
      hay = lowbuf
      needle = lpat
    }
    val pathBytes = path.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1)
    var pos = 0
    while (pos <= len) {
      val m = indexOf(hay, len, pos, needle)
      if (m < 0) return
      // phantom empty line after a trailing newline: grep emits no line there
      if (m == len && len > 0 && data(len - 1) == 0x0A) return
      val ls = lastIndexOfNL(data, m) + 1
      val j = indexOfNL(data, m, len)
      val le = if (j >= 0) j else len
      matched = true
      if (multi) {
        out.write(pathBytes)
        out.write(':')
      }
      out.write(data, ls, le - ls)
      out.write('\n')
      pos = le + 1
    }
  }

  // Recursive walk: list entries; skip symlinks; recurse subdirs; search files.
  def walk(dir: Path): Unit = {
    val stack = new java.util.ArrayDeque[Path]()
    stack.push(dir)
    while (!stack.isEmpty) {
      val d = stack.pop()
      val f = d.toFile
      val entries = f.listFiles()
      if (entries != null) {
        var k = 0
        while (k < entries.length) {
          val e = entries(k)
          val p = e.toPath
          try {
            if (!Files.isSymbolicLink(p)) {
              if (Files.isDirectory(p, LinkOption.NOFOLLOW_LINKS)) stack.push(p)
              else if (Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS)) searchFile(p.toString)
            }
          } catch { case _: Throwable => () }
          k += 1
        }
      }
    }
  }

  def usage(): Unit = {
    System.err.print("usage: scalagrep_std [-r] [-i] PATTERN PATH...\n")
    System.exit(2)
  }

  def main(args: Array[String]): Unit = {
    val paths = new java.util.ArrayList[String]()
    var noMore = false
    var idx = 0
    while (idx < args.length) {
      val a = args(idx)
      if (!noMore && a.length >= 1 && a.charAt(0) == '-' && a != "-") {
        if (a == "--") noMore = true
        else {
          var k = 1
          while (k < a.length) {
            val c = a.charAt(k)
            if (c == 'i') ci = true
            else if (c == 'r') recursive = true
            else usage()
            k += 1
          }
        }
      } else if (!patSet) {
        pat = a.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1)
        patSet = true
      } else {
        paths.add(a)
      }
      idx += 1
    }
    if (!patSet || paths.isEmpty) usage()
    lpat = new Array[Byte](pat.length)
    asciiLower(lpat, pat, pat.length)
    multi = recursive || paths.size > 1
    out = new BufferedOutputStream(System.out, 1 << 16)

    var pi = 0
    while (pi < paths.size) {
      val p = paths.get(pi)
      val pp = Paths.get(p)
      try {
        // Top level: FOLLOW symlinks (readAttributes follows by default).
        val attrs = Files.readAttributes(pp, classOf[BasicFileAttributes])
        if (attrs.isDirectory) {
          if (recursive) walk(pp)
        } else if (attrs.isRegularFile) {
          searchFile(p)
        }
      } catch { case _: Throwable => () }
      pi += 1
    }
    out.flush()
    System.exit(if (matched) 0 else 1)
  }
}
