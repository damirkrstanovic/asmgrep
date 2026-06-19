// csgrep_aot_std - idiomatic single-threaded C# compiled with NativeAOT.
// Same structure as the Mono csharp/GrepStd.cs, but the scan goes through G.Find
// (vectorized Span.IndexOf by default). No managed-runtime startup.
using System;
using System.Collections.Generic;
using System.IO;

class GrepStd {
    static byte[] pat;
    static byte[] lpat;
    static bool patSet;
    static bool ci;
    static bool recursive;
    static bool multi;
    static bool matched;
    static Stream outp;
    static byte[] lowbuf = new byte[0];

    static void SearchFile(string path) {
        byte[] data;
        try {
            data = File.ReadAllBytes(path);
        } catch {
            return;
        }
        int len = data.Length;
        int peek = Math.Min(len, 65536);
        for (int i = 0; i < peek; i++) if (data[i] == 0) return; // binary

        byte[] hay = data;
        byte[] needle = pat;
        if (ci) {
            if (lowbuf.Length < len) lowbuf = new byte[len];
            G.AsciiLower(lowbuf, data, len);
            hay = lowbuf;
            needle = lpat;
        }
        byte[] pathBytes = G.Latin1(path);
        int pos = 0;
        while (pos < len) {
            int m = G.Find(hay, len, pos, needle);
            if (m < 0) break;
            int ls = G.LastIndexOfNL(data, m) + 1;
            int j = G.IndexOfNL(data, m, len);
            int le = (j >= 0) ? j : len;
            matched = true;
            if (multi) {
                outp.Write(pathBytes, 0, pathBytes.Length);
                outp.WriteByte((byte)':');
            }
            outp.Write(data, ls, le - ls);
            outp.WriteByte((byte)'\n');
            pos = le + 1;
        }
    }

    static void Walk(string dir) {
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
            if ((attrs & FileAttributes.Directory) != 0) Walk(e);
            else SearchFile(e);
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
        outp = new BufferedStream(Console.OpenStandardOutput(), 1 << 16);

        foreach (string p in paths) {
            FileAttributes attrs;
            try {
                attrs = File.GetAttributes(p);
            } catch {
                continue;
            }
            if ((attrs & FileAttributes.Directory) != 0) {
                if (recursive) Walk(p);
            } else {
                SearchFile(p);
            }
        }
        outp.Flush();
        return matched ? 0 : 1;
    }
}
