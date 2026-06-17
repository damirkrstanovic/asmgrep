// jgrep_std_mt_tuned - concurrent Java with the memory pillar applied:
// each worker reuses ONE growable read buffer (and one lowercase buffer) across
// files; reads a 64 KB prefix first, does the NUL binary-check on that prefix,
// and only reads the rest of the file if it passed. Mirrors go/mt/main.go.
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicInteger;

public class GrepMtTuned {
    static final int PEEK = 65536;

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

    // Per-worker reusable scratch.
    static final class Scratch {
        byte[] rbuf = new byte[PEEK];   // growable read buffer, reused across files
        byte[] lowbuf = new byte[0];    // growable lowercase scratch
        ByteArrayOutputStream w = new ByteArrayOutputStream(1 << 16);
    }

    // read at most cap-off bytes into buf[off..]; returns total length in buf.
    static int readFully(InputStream in, byte[] buf, int off, int want) throws IOException {
        int n = off;
        int endTarget = off + want;
        while (n < endTarget) {
            int r = in.read(buf, n, endTarget - n);
            if (r < 0) break;
            n += r;
        }
        return n;
    }

    static boolean searchFile(String path, Scratch s) throws IOException {
        Path pp = Paths.get(path);
        long sizeL;
        try {
            BasicFileAttributes a = Files.readAttributes(pp, BasicFileAttributes.class);
            sizeL = a.size();
        } catch (IOException e) {
            return false;
        }
        if (sizeL <= 0) return false;
        int size = (int) Math.min(sizeL, Integer.MAX_VALUE);
        int peek = Math.min(size, PEEK);

        try (InputStream in = Files.newInputStream(pp)) {
            if (s.rbuf.length < peek) s.rbuf = new byte[peek];
            int got = readFully(in, s.rbuf, 0, peek);
            if (got < peek) peek = got; // short read; work with what we have
            for (int i = 0; i < peek; i++) if (s.rbuf[i] == 0) return false; // binary

            int len = peek;
            if (size > peek) {
                if (s.rbuf.length < size) {
                    byte[] nb = new byte[size];
                    System.arraycopy(s.rbuf, 0, nb, 0, peek);
                    s.rbuf = nb;
                }
                len = readFully(in, s.rbuf, peek, size - peek);
            }
            byte[] data = s.rbuf;

            byte[] hay = data;
            byte[] needle = pat;
            if (ci) {
                if (s.lowbuf.length < len) s.lowbuf = new byte[len];
                asciiLower(s.lowbuf, data, len);
                hay = s.lowbuf;
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
                    s.w.write(pathBytes, 0, pathBytes.length);
                    s.w.write(':');
                }
                s.w.write(data, ls, le - ls);
                s.w.write('\n');
                pos = le + 1;
            }
            return found;
        } catch (IOException e) {
            return false;
        }
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
                Scratch s = new Scratch();
                try {
                    while (true) {
                        int i = idx.getAndIncrement();
                        if (i >= files.size()) break;
                        s.w.reset();
                        boolean f = searchFile(files.get(i), s);
                        if (f) anyMatch.set(true);
                        if (s.w.size() > 0) {
                            synchronized (outLock) {
                                s.w.writeTo(out);
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
