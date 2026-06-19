// Shared helpers for the NativeAOT C# variants. The scan (G.Find) is switched at
// compile time: -p:DefineConstants=HANDROLLED keeps the same scalar byte loop as
// the Mono build (isolates AOT-vs-Mono codegen); the default uses the BCL's
// vectorized ReadOnlySpan<byte>.IndexOf (isolates the SIMD algorithm).
using System;

static class G {
    // String -> raw bytes, one byte per char (matches Java/Mono ISO-8859-1 output).
    public static byte[] Latin1(string s) {
        byte[] b = new byte[s.Length];
        for (int i = 0; i < s.Length; i++) b[i] = (byte)s[i];
        return b;
    }

    // ASCII-only, length-preserving lowercase (matches grep -iF).
    public static void AsciiLower(byte[] dst, byte[] src, int len) {
        for (int i = 0; i < len; i++) {
            byte b = src[i];
            dst[i] = (b >= (byte)'A' && b <= (byte)'Z') ? (byte)(b + 32) : b;
        }
    }

    public static int LastIndexOfNL(byte[] data, int m) {
        for (int i = m - 1; i >= 0; i--) if (data[i] == (byte)'\n') return i;
        return -1;
    }

    public static int IndexOfNL(byte[] data, int from, int len) {
        for (int i = from; i < len; i++) if (data[i] == (byte)'\n') return i;
        return -1;
    }

    // index of needle in hay[from:len], or -1. Empty needle returns from.
    public static int Find(byte[] hay, int len, int from, byte[] needle) {
#if HANDROLLED
        int n = needle.Length;
        if (n == 0) return from;
        int end = len - n;
        for (int i = from; i <= end; i++) {
            int j = 0;
            while (j < n && hay[i + j] == needle[j]) j++;
            if (j == n) return i;
        }
        return -1;
#else
        if (needle.Length == 0) return from;
        if (from >= len) return -1;
        int idx = new ReadOnlySpan<byte>(hay, from, len - from).IndexOf(new ReadOnlySpan<byte>(needle));
        return idx < 0 ? -1 : from + idx;
#endif
    }
}
