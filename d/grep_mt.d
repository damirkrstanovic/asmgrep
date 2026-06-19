// dgrep_std_mt - naive multithreaded D grep -F clone. Collect the file list,
// then one worker thread per CPU pulls files off a shared atomic index. Each
// file is read IN FULL into a FRESH GC buffer before the binary check (the
// deliberately allocation-heavy tier). Mirrors pascal/grep_mt.pas.
import core.sys.posix.unistd : write, read, close;
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.sys.stat : stat_t, lstat, stat, S_ISDIR, S_ISREG, S_ISLNK;
import core.sys.posix.dirent : opendir, readdir, closedir, DIR, dirent;
import core.stdc.string : strlen;
import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.atomic : atomicOp, atomicStore;
import core.sync.mutex : Mutex;

__gshared ubyte[] pat;
__gshared ubyte[] lpat;
__gshared bool ci;
__gshared bool recursive;
__gshared bool multi;
shared int matched;

__gshared string[] files;
shared size_t nextIdx; // fetch-add; first claim is index 0
__gshared Mutex outLock;

void asciiLower(ubyte[] dst, const(ubyte)[] src) {
    foreach (i, b; src)
        dst[i] = (b >= 'A' && b <= 'Z') ? cast(ubyte)(b + 32) : b;
}

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

// Search one file; build its full output block, then emit under outLock.
void searchFile(string path) {
    auto cpath = (path ~ '\0');
    int fd = open(cpath.ptr, O_RDONLY);
    if (fd < 0) return;
    auto data = readAll(fd); // fresh full buffer each file (naive)
    close(fd);
    size_t len = data.length;

    size_t peek = len < 65536 ? len : 65536;
    for (size_t i = 0; i < peek; i++)
        if (data[i] == 0) return; // binary

    const(ubyte)* hay = data.ptr;
    const(ubyte)* needle = pat.ptr;
    size_t nlen = pat.length;
    ubyte[] low;
    if (ci) {
        low = new ubyte[len];
        asciiLower(low, data[0 .. len]);
        hay = low.ptr;
        needle = lpat.ptr;
        nlen = lpat.length;
    }

    auto pathBytes = cast(const(ubyte)[]) path;
    ubyte[] ob;
    ob.reserve(4096);
    size_t pos = 0;
    while (pos < len) {
        auto m = byteIndex(hay, len, needle, nlen, pos);
        if (m < 0) break;
        auto ls = lineStart(data.ptr, m);
        auto le = lineEnd(data.ptr, m, len);
        atomicStore(matched, 1);
        if (multi) { ob ~= pathBytes; ob ~= ':'; }
        if (le > ls) ob ~= data[ls .. le];
        ob ~= '\n';
        pos = le + 1;
    }

    if (ob.length > 0) {
        outLock.lock();
        write(1, ob.ptr, ob.length);
        outLock.unlock();
    }
}

void worker() {
    while (true) {
        auto idx = atomicOp!"+="(nextIdx, 1) - 1; // claim then read 0-based
        if (idx >= files.length) break;
        searchFile(files[idx]);
    }
}

void addFile(string path) { files ~= path; }

void walkDir(string dir) {
    auto cdir = (dir ~ '\0');
    DIR* pd = opendir(cdir.ptr);
    if (pd is null) return;
    for (dirent* ent = readdir(pd); ent !is null; ent = readdir(pd)) {
        auto nlen = strlen(ent.d_name.ptr);
        auto name = cast(string) ent.d_name[0 .. nlen].idup;
        if (name == "." || name == "..") continue;
        collect(dir ~ "/" ~ name);
    }
    closedir(pd);
}

void collect(string path) {
    auto cpath = (path ~ '\0');
    stat_t st;
    if (lstat(cpath.ptr, &st) != 0) return;
    if (S_ISLNK(st.st_mode)) return;
    if (S_ISDIR(st.st_mode)) {
        if (recursive) walkDir(path);
    } else if (S_ISREG(st.st_mode)) {
        addFile(path);
    }
}

void usage() {
    immutable string msg = "usage: dgrep [-r] [-i] PATTERN PATH...\n";
    write(2, msg.ptr, msg.length);
    exit(2);
}

int numThreads() {
    import std.parallelism : totalCPUs;
    int n = totalCPUs;
    return n < 1 ? 6 : n;
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
            addFile(p);
        } else if (S_ISLNK(st.st_mode)) {
            if (stat(cp.ptr, &st) == 0) {
                if (S_ISREG(st.st_mode)) addFile(p);
                else if (S_ISDIR(st.st_mode) && recursive) walkDir(p);
            }
        }
    }

    outLock = new Mutex();
    int nt = numThreads();
    if (nt > files.length) nt = cast(int) files.length;
    if (nt < 1) nt = 1;

    if (files.length > 0) {
        Thread[] threads;
        threads.length = nt;
        foreach (i; 0 .. nt) {
            threads[i] = new Thread(&worker);
            threads[i].start();
        }
        foreach (t; threads) t.join();
    }

    exit(matched != 0 ? 0 : 1);
}
