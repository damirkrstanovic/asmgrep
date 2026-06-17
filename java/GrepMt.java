// jgrep_std_mt - idiomatic concurrent Java: collect file list, then a fixed
// thread pool over it. Each file gets a FRESH full-size byte[] (Files.readAllBytes)
// read IN FULL before the binary check (the deliberately allocation-heavy tier).
// Per-file output buffered, flushed under a lock so files don't interleave.
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicInteger;

public class GrepMt {
    static byte[] pat;
    static byte[] lpat;
    static boolean patSet;
    static boolean ci;
    static boolean recursive;
    static boolean multi;

    static final java.util.concurrent.atomic.AtomicBoolean anyMatch =
        new java.util.concurrent.atomic.AtomicBoolean(false);
    static OutputStream out;
    static final Object outLock = new Object();
    static final ArrayList<String> files = new ArrayList<>();
    static final AtomicInteger idx = new AtomicInteger(0);

    static void asciiLower(byte[] dst, byte[] src, int len) {
        for (int i = 0; i < len; i++) {
            byte b = src[i];
            if (b >= 'A' && b <= 'Z') dst[i] = (byte) (b + 32);
            else dst[i] = b;
        }
    }

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

    // returns true if matched; writes output into w. Fresh full read per file.
    static boolean searchFile(String path, ByteArrayOutputStream w, byte[][] lowbufRef) throws IOException {
        byte[] data;
        try {
            data = Files.readAllBytes(Paths.get(path)); // fresh full-size alloc, full read
        } catch (IOException e) {
            return false;
        }
        int len = data.length;
        int peek = Math.min(len, 65536);
        for (int i = 0; i < peek; i++) if (data[i] == 0) return false; // binary

        byte[] hay = data;
        byte[] needle = pat;
        if (ci) {
            byte[] lowbuf = lowbufRef[0];
            if (lowbuf.length < len) { lowbuf = new byte[len]; lowbufRef[0] = lowbuf; }
            asciiLower(lowbuf, data, len);
            hay = lowbuf;
            needle = lpat;
        }
        byte[] pathBytes = path.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1);
        boolean found = false;
        int pos = 0;
        // pos < len: empty needle matches each line once (grep -F "" semantics).
        while (pos < len) {
            int m = indexOf(hay, len, pos, needle);
            if (m < 0) break;
            int ls = lastIndexOfNL(data, m) + 1;
            int j = indexOfNL(data, m, len);
            int le = (j >= 0) ? j : len;
            found = true;
            if (multi) {
                w.write(pathBytes, 0, pathBytes.length);
                w.write(':');
            }
            w.write(data, ls, le - ls);
            w.write('\n');
            pos = le + 1;
        }
        return found;
    }

    static void collect(Path dir) {
        try {
            Files.walkFileTree(dir, new java.nio.file.SimpleFileVisitor<Path>() {
                @Override
                public java.nio.file.FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
                    if (attrs.isRegularFile()) files.add(file.toString());
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

    public static void main(String[] args) throws Exception {
        ArrayList<String> paths = new ArrayList<>();
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

        for (String p : paths) {
            Path pp = Paths.get(p);
            BasicFileAttributes attrs;
            try {
                attrs = Files.readAttributes(pp, BasicFileAttributes.class);
            } catch (IOException e) {
                continue;
            }
            if (attrs.isDirectory()) {
                if (recursive) collect(pp);
            } else {
                files.add(p);
            }
        }

        out = new BufferedOutputStream(System.out, 1 << 16);
        int nthreads = Runtime.getRuntime().availableProcessors();
        Thread[] threads = new Thread[nthreads];
        for (int t = 0; t < nthreads; t++) {
            threads[t] = new Thread(() -> {
                ByteArrayOutputStream buf = new ByteArrayOutputStream(1 << 16);
                byte[][] lowbufRef = new byte[][]{ new byte[0] };
                try {
                    while (true) {
                        int i = idx.getAndIncrement();
                        if (i >= files.size()) break;
                        buf.reset();
                        boolean f = searchFile(files.get(i), buf, lowbufRef);
                        if (f) anyMatch.set(true);
                        if (buf.size() > 0) {
                            synchronized (outLock) {
                                buf.writeTo(out);
                            }
                        }
                    }
                } catch (IOException e) { /* ignore */ }
            });
            threads[t].start();
        }
        for (Thread th : threads) th.join();
        out.flush();
        System.exit(anyMatch.get() ? 0 : 1);
    }
}
