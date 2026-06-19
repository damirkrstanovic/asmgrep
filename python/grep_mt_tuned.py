#!/usr/bin/env python3
# pygrep_std_mt_tuned - multiprocessing + the memory pillar (mirrors
# c/grep_std_mt.c): each worker REUSES a bytearray buffer via readinto() and
# reads a 64KB PREFIX first, binary-checks it, and reads the rest only if the
# file isn't binary (so a huge .git pack is never fully faulted in then skipped).
import os
import sys
import stat
from multiprocessing import Pool, cpu_count

_LOWER = bytes((c + 32) if 65 <= c <= 90 else c for c in range(256))
_PREFIX = 65536

_PAT = _LPAT = b""
_CI = _MULTI = False
# per-worker reused buffer (grown to the largest file seen, never shrunk)
_BUF = bytearray(_PREFIX)


def _init(pat, lpat, ci, multi):
    global _PAT, _LPAT, _CI, _MULTI, _BUF
    _PAT, _LPAT, _CI, _MULTI = pat, lpat, ci, multi
    _BUF = bytearray(_PREFIX)


def _search_one(path):
    global _BUF
    try:
        f = open(path, "rb")
    except OSError:
        return (False, b"")
    try:
        try:
            sz = os.fstat(f.fileno()).st_size
        except OSError:
            sz = -1
        if sz == 0:
            return (False, b"")
        # read only a prefix first into the reused buffer, binary-check it
        peek = _PREFIX if (sz < 0 or sz > _PREFIX) else sz
        if peek > len(_BUF):
            _BUF = bytearray(peek)
        got = f.readinto(memoryview(_BUF)[:peek])
        if got == 0:
            return (False, b"")
        if _BUF.find(b"\x00", 0, got) != -1:
            return (False, b"")     # binary: skip, rest unread
        # read the rest only if not binary
        if sz < 0 or sz > got:
            total = got
            if sz > len(_BUF):
                # grow, preserving the prefix already read
                nb = bytearray(sz)
                nb[:total] = _BUF[:total]
                _BUF = nb
            while True:
                if total >= len(_BUF):
                    _BUF.extend(b"\x00" * len(_BUF))   # unknown size: double
                n = f.readinto(memoryview(_BUF)[total:])
                if n == 0:
                    break
                total += n
            got = total
    finally:
        f.close()

    # snapshot the prefix-of-buffer to plain bytes bounded by `got` so the scan
    # never sees stale bytes left over from a previously larger file
    data = bytes(memoryview(_BUF)[:got])
    if _CI:
        hay = data.translate(_LOWER)
        needle = _LPAT
    else:
        hay = data
        needle = _PAT
    out = []
    matched = False
    pos = 0
    n = got
    while pos <= n:
        m = hay.find(needle, pos)
        if m < 0:
            break
        if m == n and n > 0 and data[n - 1] == 0x0A:
            break
        ls = data.rfind(b"\n", 0, m) + 1
        le = data.find(b"\n", m)
        if le < 0:
            le = n
        matched = True
        if _MULTI:
            out.append(path)
            out.append(b":")
        out.append(data[ls:le])
        out.append(b"\n")
        pos = le + 1
    return (matched, b"".join(out))


def collect(paths, r):
    files = []
    for p in paths:
        pb = p.encode("utf-8", "surrogateescape")
        try:
            st = os.stat(pb)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            if not r:
                continue
            stack = [pb]
            while stack:
                d = stack.pop()
                try:
                    with os.scandir(d) as it:
                        for e in it:
                            try:
                                if e.is_symlink():
                                    continue
                                if e.is_dir(follow_symlinks=False):
                                    stack.append(e.path)
                                elif e.is_file(follow_symlinks=False):
                                    files.append(e.path)
                            except OSError:
                                continue
                except OSError:
                    continue
        elif stat.S_ISREG(st.st_mode):
            files.append(pb)
    return files


def main(argv):
    ci = r = False
    pat = None
    paths = []
    no_more = False
    for a in argv[1:]:
        if not no_more and a.startswith("-") and a != "-":
            if a == "--":
                no_more = True
                continue
            for q in a[1:]:
                if q == "i":
                    ci = True
                elif q == "r":
                    r = True
                else:
                    sys.stderr.write("usage: pygrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n")
                    return 2
        elif pat is None:
            pat = a
        else:
            paths.append(a)
    if pat is None or not paths:
        sys.stderr.write("usage: pygrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n")
        return 2

    patb = pat.encode("utf-8", "surrogateescape")
    lpat = patb.translate(_LOWER)
    multi = r or len(paths) > 1

    files = collect(paths, r)

    matched = False
    if files:
        nproc = min(cpu_count(), 16)
        out = sys.stdout.buffer
        if len(files) < 2 or nproc < 2:
            _init(patb, lpat, ci, multi)
            buf = []
            for path in files:
                m, o = _search_one(path)
                if m:
                    matched = True
                    buf.append(o)
            if buf:
                out.write(b"".join(buf))
        else:
            chunk = max(1, len(files) // (nproc * 4))
            with Pool(nproc, initializer=_init,
                      initargs=(patb, lpat, ci, multi)) as pool:
                buf = []
                for m, o in pool.imap_unordered(_search_one, files, chunk):
                    if m:
                        matched = True
                        if o:
                            buf.append(o)
                    if len(buf) >= 256:
                        out.write(b"".join(buf))
                        buf = []
                if buf:
                    out.write(b"".join(buf))
        out.flush()
    return 0 if matched else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
