// jgrep_std - idiomatic single-threaded Java: NIO Files.readAllBytes + manual
// byte-array search (no regex), buffered stdout. Mirrors go/grep.go semantics.
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.BasicFileAttributes;

public class GrepStd {
    static byte[] pat;
    static byte[] lpat;
    static boolean patSet;
    static boolean ci;
    static boolean recursive;
    static boolean multi;
    static boolean matched;
    static OutputStream out;
    static byte[] lowbuf = new byte[0]; // reused ASCII-lowercase scratch

    // ASCII-only, length-preserving lowercase (matches grep -iF).
    static void asciiLower(byte[] dst, byte[] src, int len) {
        for (int i = 0; i < len; i++) {
            byte b = src[i];
            if (b >= 'A' && b <= 'Z') dst[i] = (byte) (b + 32);
            else dst[i] = b;
        }
    }

    // index of needle in hay[from:len], or -1. Empty needle returns from.
    static int indexOf(byte[] hay, int len, int from, byte[] needle) {
        int n = needle.length;
        if (n == 0) return from;
        int end = len - n;
        for (int i = from; i <= end; i++) {
            int j = 0;
            while (j < n && hay[i + j] == needle[j]) j++;
            if (j == n) return i;
        }
        return -1;
    }

    static int lastIndexOfNL(byte[] data, int m) {
        for (int i = m - 1; i >= 0; i--) if (data[i] == '\n') return i;
        return -1;
    }

    static int indexOfNL(byte[] data, int from, int len) {
        for (int i = from; i < len; i++) if (data[i] == '\n') return i;
        return -1;
    }

    static void searchFile(String path) throws IOException {
        byte[] data;
        try {
            data = Files.readAllBytes(Paths.get(path));
        } catch (IOException e) {
            return;
        }
        int len = data.length;
        int peek = Math.min(len, 65536);
        for (int i = 0; i < peek; i++) if (data[i] == 0) return; // binary

        byte[] hay = data;
        byte[] needle = pat;
        if (ci) {
            if (lowbuf.length < len) lowbuf = new byte[len];
            asciiLower(lowbuf, data, len);
            hay = lowbuf;
            needle = lpat;
        }
        byte[] pathBytes = path.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);
        int pos = 0;
        // pos < len (not <=): an empty needle would otherwise yield a phantom
        // match at pos==len (trailing blank line); grep -F "" prints each line once.
        while (pos < len) {
            int m = indexOf(hay, len, pos, needle);
            if (m < 0) break;
            int ls = lastIndexOfNL(data, m) + 1;
            int j = indexOfNL(data, m, len);
            int le = (j >= 0) ? j : len;
            matched = true;
            if (multi) {
                out.write(pathBytes);
                out.write(':');
            }
            out.write(data, ls, le - ls);
            out.write('\n');
            pos = le + 1;
        }
    }

    static void walk(Path dir) {
        try {
            Files.walkFileTree(dir, new java.nio.file.SimpleFileVisitor<Path>() {
                @Override
                public java.nio.file.FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                    if (attrs.isRegularFile()) searchFile(file.toString());
                    return java.nio.file.FileVisitResult.CONTINUE;
                }
                @Override
                public java.nio.file.FileVisitResult visitFileFailed(Path file, IOException exc) {
                    return java.nio.file.FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException e) { /* ignore */ }
    }

    static void usage() {
        System.err.print("usage: jgrep [-r] [-i] PATTERN PATH...\n");
        System.exit(2);
    }

    public static void main(String[] args) throws IOException {
        java.util.ArrayList<String> paths = new java.util.ArrayList<>();
        boolean noMore = false;
        for (String a : args) {
            if (!noMore && a.length() >= 2 && a.charAt(0) == '-') {
                if (a.equals("--")) { noMore = true; continue; }
                for (int k = 1; k < a.length(); k++) {
                    char c = a.charAt(k);
                    if (c == 'i') ci = true;
                    else if (c == 'r') recursive = true;
                    else usage();
                }
            } else if (!patSet) {
                pat = a.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);
                patSet = true;
            } else {
                paths.add(a);
            }
        }
        if (!patSet || paths.isEmpty()) usage();
        lpat = new byte[pat.length];
        asciiLower(lpat, pat, pat.length);
        multi = recursive || paths.size() > 1;
        out = new BufferedOutputStream(System.out, 1 << 16);

        for (String p : paths) {
            Path pp = Paths.get(p);
            BasicFileAttributes attrs;
            try {
                attrs = Files.readAttributes(pp, BasicFileAttributes.class);
            } catch (IOException e) {
                continue;
            }
            if (attrs.isDirectory()) {
                if (recursive) walk(pp);
            } else {
                searchFile(p);
            }
        }
        out.flush();
        System.exit(matched ? 0 : 1);
    }
}
