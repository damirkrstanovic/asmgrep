// dgrep_std - idiomatic single-threaded D grep -F clone. std.file.read +
// hand-rolled byte search (no regex), manual output buffer flushed to fd 1.
// Native binary (dmd) with a GC runtime; mirrors pascal/grep_std.pas semantics.
import core.sys.posix.unistd : write, read, close;
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.sys.stat : stat_t, lstat, stat, S_ISDIR, S_ISREG, S_ISLNK;
import core.sys.posix.dirent : opendir, readdir, closedir, DIR, dirent;
import core.stdc.string : strlen;
import core.stdc.stdlib : exit;

__gshared ubyte[] pat;
__gshared ubyte[] lpat;
__gshared bool ci;
__gshared bool recursive;
__gshared bool multi;
__gshared bool matched;

enum OUTCAP = 1 << 16;
__gshared ubyte[OUTCAP] outBuf;
__gshared size_t outLen;

void flushOut() {
    if (outLen > 0) {
        write(1, outBuf.ptr, outLen);
        outLen = 0;
    }
}

void outBytes(const(ubyte)* p, size_t n) {
    if (n == 0) return;
    if (n >= OUTCAP) {
        flushOut();
        write(1, p, n);
        return;
    }
    if (outLen + n > OUTCAP) flushOut();
    outBuf[outLen .. outLen + n] = p[0 .. n];
    outLen += n;
}

void outByte(ubyte b) {
    if (outLen + 1 > OUTCAP) flushOut();
    outBuf[outLen] = b;
    outLen++;
}

// ASCII-only, length-preserving lowercase (matches grep -iF).
void asciiLower(ubyte[] dst, const(ubyte)[] src) {
    foreach (i, b; src)
        dst[i] = (b >= 'A' && b <= 'Z') ? cast(ubyte)(b + 32) : b;
}

// First index >= from where needle occurs in hay[0..len]; -1 if none.
// Empty needle returns from.
ptrdiff_t byteIndex(const(ubyte)* hay, size_t len, const(ubyte)* needle, size_t nlen, size_t from) {
    if (nlen == 0) return from;
    if (from + nlen > len) return -1;
    immutable ubyte first = needle[0];
    size_t i = from;
    immutable size_t last = len - nlen;
    while (i <= last) {
        if (hay[i] == first) {
            size_t j = 1;
            while (j < nlen && hay[i + j] == needle[j]) j++;
            if (j == nlen) return i;
        }
        i++;
    }
    return -1;
}

ptrdiff_t lineStart(const(ubyte)* data, ptrdiff_t m) {
    ptrdiff_t i = m - 1;
    while (i >= 0) {
        if (data[i] == '\n') return i + 1;
        i--;
    }
    return 0;
}

ptrdiff_t lineEnd(const(ubyte)* data, ptrdiff_t m, ptrdiff_t len) {
    ptrdiff_t i = m;
    while (i < len) {
        if (data[i] == '\n') return i;
        i++;
    }
    return len;
}

__gshared ubyte[] lowbuf; // reused ASCII-lowercase scratch

void searchFile(string path) {
    auto cpath = (path ~ '\0');
    int fd = open(cpath.ptr, O_RDONLY);
    if (fd < 0) return;
    stat_t st;
    // read the whole file into a fresh buffer
    auto data = readAll(fd);
    close(fd);
    size_t len = data.length;

    size_t peek = len < 65536 ? len : 65536;
    for (size_t i = 0; i < peek; i++)
        if (data[i] == 0) return; // binary

    const(ubyte)* hay = data.ptr;
    const(ubyte)* needle = pat.ptr;
    size_t nlen = pat.length;
    if (ci) {
        if (lowbuf.length < len) lowbuf.length = len;
        asciiLower(lowbuf, data[0 .. len]);
        hay = lowbuf.ptr;
        needle = lpat.ptr;
        nlen = lpat.length;
    }

    auto pathBytes = cast(const(ubyte)[]) path;
    size_t pos = 0;
    // pos < len (not <=): empty needle would otherwise yield a phantom match at
    // pos==len; grep -F "" prints each line once.
    while (pos < len) {
        auto m = byteIndex(hay, len, needle, nlen, pos);
        if (m < 0) break;
        auto ls = lineStart(data.ptr, m);
        auto le = lineEnd(data.ptr, m, len);
        matched = true;
        if (multi) {
            outBytes(pathBytes.ptr, pathBytes.length);
            outByte(':');
        }
        if (le > ls) outBytes(data.ptr + ls, le - ls);
        outByte('\n');
        pos = le + 1;
    }
}

// Read an entire fd into a GC buffer (size unknown a priori for some fds, but
// regular files give a size hint via fstat; we just grow).
ubyte[] readAll(int fd) {
    ubyte[] buf;
    buf.length = 65536;
    size_t off = 0;
    while (true) {
        if (off == buf.length) buf.length = buf.length * 2;
        auto got = read(fd, buf.ptr + off, buf.length - off);
        if (got <= 0) break;
        off += got;
    }
    return buf[0 .. off];
}

void walkDir(string dir) {
    auto cdir = (dir ~ '\0');
    DIR* pd = opendir(cdir.ptr);
    if (pd is null) return;
    for (dirent* ent = readdir(pd); ent !is null; ent = readdir(pd)) {
        auto nlen = strlen(ent.d_name.ptr);
        auto name = cast(string) ent.d_name[0 .. nlen].idup;
        if (name == "." || name == "..") continue;
        visit(dir ~ "/" ~ name);
    }
    closedir(pd);
}

void visit(string path) {
    auto cpath = (path ~ '\0');
    stat_t st;
    if (lstat(cpath.ptr, &st) != 0) return;
    if (S_ISLNK(st.st_mode)) return; // never follow symlinks during recursion
    if (S_ISDIR(st.st_mode)) {
        if (recursive) walkDir(path);
    } else if (S_ISREG(st.st_mode)) {
        searchFile(path);
    }
}

void usage() {
    immutable string msg = "usage: dgrep [-r] [-i] PATTERN PATH...\n";
    write(2, msg.ptr, msg.length);
    exit(2);
}

void main(string[] args) {
    string patStr;
    bool patSet;
    string[] paths;
    bool noMore;
    foreach (a; args[1 .. $]) {
        if (!noMore && a.length >= 2 && a[0] == '-') {
            if (a == "--") { noMore = true; continue; }
            foreach (c; a[1 .. $]) {
                if (c == 'i') ci = true;
                else if (c == 'r') recursive = true;
                else usage();
            }
        } else if (!patSet) {
            patStr = a;
            patSet = true;
        } else {
            paths ~= a;
        }
    }
    if (!patSet || paths.length == 0) usage();

    pat = cast(ubyte[]) patStr.dup;
    lpat = new ubyte[pat.length];
    asciiLower(lpat, pat);
    multi = recursive || paths.length > 1;

    foreach (p; paths) {
        auto cp = (p ~ '\0');
        stat_t st;
        if (lstat(cp.ptr, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            if (recursive) walkDir(p);
        } else if (S_ISREG(st.st_mode)) {
            searchFile(p);
        } else if (S_ISLNK(st.st_mode)) {
            // top-level symlink arg: resolve once like grep -F does.
            if (stat(cp.ptr, &st) == 0) {
                if (S_ISREG(st.st_mode)) searchFile(p);
                else if (S_ISDIR(st.st_mode) && recursive) walkDir(p);
            }
        }
    }

    flushOut();
    exit(matched ? 0 : 1);
}
