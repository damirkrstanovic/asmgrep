// csgrep_aot_std_mt_tuned - multithreaded + the memory pillar, NativeAOT. Each
// worker reuses one growable read buffer (+ lowercase buffer), reads a 64 KB
// prefix first, NUL-checks it, reads the rest only if it passed. Same as Mono
// csharp/GrepMtTuned.cs but scan via G.Find (vectorized Span.IndexOf default).
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

class GrepMtTuned {
    const int PEEK = 65536;

    static byte[] pat;
    static byte[] lpat;
    static bool patSet;
    static bool ci;
    static bool recursive;
    static bool multi;

    static int anyMatch;
    static Stream outp;
    static readonly object outLock = new object();
    static readonly List<string> files = new List<string>();
    static int idx;

    sealed class Scratch {
        public byte[] rbuf = new byte[PEEK];
        public byte[] lowbuf = new byte[0];
        public MemoryStream w = new MemoryStream(1 << 16);
    }

    static int ReadFully(Stream s, byte[] buf, int off, int want) {
        int n = off;
        int endTarget = off + want;
        while (n < endTarget) {
            int r = s.Read(buf, n, endTarget - n);
            if (r <= 0) break;
            n += r;
        }
        return n;
    }

    static bool SearchFile(string path, Scratch s) {
        long sizeL;
        try {
            sizeL = new FileInfo(path).Length;
        } catch {
            return false;
        }
        if (sizeL <= 0) return false;
        int size = (int)Math.Min(sizeL, int.MaxValue);
        int peek = Math.Min(size, PEEK);

        try {
            using (var fin = new FileStream(path, FileMode.Open, FileAccess.Read)) {
                if (s.rbuf.Length < peek) s.rbuf = new byte[peek];
                int got = ReadFully(fin, s.rbuf, 0, peek);
                if (got < peek) peek = got;
                for (int i = 0; i < peek; i++) if (s.rbuf[i] == 0) return false; // binary

                int len = peek;
                if (size > peek) {
                    if (s.rbuf.Length < size) {
                        byte[] nb = new byte[size];
                        Array.Copy(s.rbuf, 0, nb, 0, peek);
                        s.rbuf = nb;
                    }
                    len = ReadFully(fin, s.rbuf, peek, size - peek);
                }
                byte[] data = s.rbuf;

                byte[] hay = data;
                byte[] needle = pat;
                if (ci) {
                    if (s.lowbuf.Length < len) s.lowbuf = new byte[len];
                    G.AsciiLower(s.lowbuf, data, len);
                    hay = s.lowbuf;
                    needle = lpat;
                }
                byte[] pathBytes = G.Latin1(path);
                bool found = false;
                int pos = 0;
                while (pos < len) {
                    int m = G.Find(hay, len, pos, needle);
                    if (m < 0) break;
                    int ls = G.LastIndexOfNL(data, m) + 1;
                    int j = G.IndexOfNL(data, m, len);
                    int le = (j >= 0) ? j : len;
                    found = true;
                    if (multi) {
                        s.w.Write(pathBytes, 0, pathBytes.Length);
                        s.w.WriteByte((byte)':');
                    }
                    s.w.Write(data, ls, le - ls);
                    s.w.WriteByte((byte)'\n');
                    pos = le + 1;
                }
                return found;
            }
        } catch {
            return false;
        }
    }

    static void Collect(string dir) {
        string[] entries;
        try {
            entries = Directory.GetFileSystemEntries(dir);
        } catch {
            return;
        }
        foreach (string e in entries) {
            FileAttributes attrs;
            try {
                attrs = File.GetAttributes(e);
            } catch {
                continue;
            }
            if ((attrs & FileAttributes.ReparsePoint) != 0) continue; // skip symlinks
            if ((attrs & FileAttributes.Directory) != 0) Collect(e);
            else files.Add(e);
        }
    }

    static void Usage() {
        Console.Error.Write("usage: csgrep [-r] [-i] PATTERN PATH...\n");
        Environment.Exit(2);
    }

    static int Main(string[] args) {
        var paths = new List<string>();
        bool noMore = false;
        foreach (string a in args) {
            if (!noMore && a.Length >= 2 && a[0] == '-') {
                if (a == "--") { noMore = true; continue; }
                for (int k = 1; k < a.Length; k++) {
                    char c = a[k];
                    if (c == 'i') ci = true;
                    else if (c == 'r') recursive = true;
                    else Usage();
                }
            } else if (!patSet) {
                pat = G.Latin1(a);
                patSet = true;
            } else {
                paths.Add(a);
            }
        }
        if (!patSet || paths.Count == 0) Usage();
        lpat = new byte[pat.Length];
        G.AsciiLower(lpat, pat, pat.Length);
        multi = recursive || paths.Count > 1;

        foreach (string p in paths) {
            FileAttributes attrs;
            try {
                attrs = File.GetAttributes(p);
            } catch {
                continue;
            }
            if ((attrs & FileAttributes.Directory) != 0) {
                if (recursive) Collect(p);
            } else {
                files.Add(p);
            }
        }

        outp = new BufferedStream(Console.OpenStandardOutput(), 1 << 16);
        int nthreads = Environment.ProcessorCount;
        var threads = new Thread[nthreads];
        for (int t = 0; t < nthreads; t++) {
            threads[t] = new Thread(() => {
                var s = new Scratch();
                while (true) {
                    int i = Interlocked.Increment(ref idx) - 1;
                    if (i >= files.Count) break;
                    s.w.SetLength(0);
                    bool f = SearchFile(files[i], s);
                    if (f) Interlocked.Exchange(ref anyMatch, 1);
                    if (s.w.Length > 0) {
                        lock (outLock) {
                            s.w.WriteTo(outp);
                        }
                    }
                }
            });
            threads[t].Start();
        }
        foreach (var th in threads) th.Join();
        outp.Flush();
        return anyMatch != 0 ? 0 : 1;
    }
}
