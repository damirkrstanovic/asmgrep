// csgrep_aot_std_mt - naive multithreaded C# compiled with NativeAOT. Collect the
// file list, fixed thread pool, FRESH full read per file before the binary check
// (allocation-heavy tier). Same as Mono csharp/GrepMt.cs but scan via G.Find.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

class GrepMt {
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

    static bool SearchFile(string path, MemoryStream w, ref byte[] lowbuf) {
        byte[] data;
        try {
            data = File.ReadAllBytes(path);
        } catch {
            return false;
        }
        int len = data.Length;
        int peek = Math.Min(len, 65536);
        for (int i = 0; i < peek; i++) if (data[i] == 0) return false; // binary

        byte[] hay = data;
        byte[] needle = pat;
        if (ci) {
            if (lowbuf.Length < len) lowbuf = new byte[len];
            G.AsciiLower(lowbuf, data, len);
            hay = lowbuf;
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
                w.Write(pathBytes, 0, pathBytes.Length);
                w.WriteByte((byte)':');
            }
            w.Write(data, ls, le - ls);
            w.WriteByte((byte)'\n');
            pos = le + 1;
        }
        return found;
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
                var buf = new MemoryStream(1 << 16);
                byte[] lowbuf = new byte[0];
                while (true) {
                    int i = Interlocked.Increment(ref idx) - 1;
                    if (i >= files.Count) break;
                    buf.SetLength(0);
                    bool f = SearchFile(files[i], buf, ref lowbuf);
                    if (f) Interlocked.Exchange(ref anyMatch, 1);
                    if (buf.Length > 0) {
                        lock (outLock) {
                            buf.WriteTo(outp);
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
