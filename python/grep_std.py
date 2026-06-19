#!/usr/bin/env python3
# pygrep_std - idiomatic single-threaded Python: os.scandir recursive walk +
# whole-file read + bytes.find scan + NUL-in-first-64KB binary skip.
# Mirrors c/grep_std.c. stdlib all the way; the scan (bytes.find / translate)
# is C-backed under the interpreter.
import os
import sys
import stat

# 256-byte ASCII-lowercase translation table (C-backed bytes.translate).
_LOWER = bytes((c + 32) if 65 <= c <= 90 else c for c in range(256))


def search_file(path, pat, lpat, ci, multi, out):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    if not data:
        return False
    peek = data[:65536]
    if b"\x00" in peek:                       # binary skip
        return False

    if ci:
        hay = data.translate(_LOWER)
        needle = lpat
    else:
        hay = data
        needle = pat
    matched = False
    pos = 0
    n = len(data)
    while pos <= n:
        m = hay.find(needle, pos)
        if m < 0:
            break
        # phantom empty line after a trailing newline: grep emits no line there
        if m == n and n > 0 and data[n - 1] == 0x0A:
            break
        ls = data.rfind(b"\n", 0, m) + 1      # prev '\n'+1 (or 0)
        le = data.find(b"\n", m)
        if le < 0:
            le = n
        matched = True
        if multi:
            out.append(path)
            out.append(b":")
        out.append(data[ls:le])
        out.append(b"\n")
        pos = le + 1
    return matched


def walk(path, pat, lpat, ci, multi, out):
    matched = False
    stack = [path]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue          # don't follow symlinks (grep -r)
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        elif e.is_file(follow_symlinks=False):
                            if search_file(e.path, pat, lpat, ci, multi, out):
                                matched = True
                    except OSError:
                        continue
        except OSError:
            continue
    return matched


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
                    sys.stderr.write("usage: pygrep_std [-r] [-i] PATTERN PATH...\n")
                    return 2
        elif pat is None:
            pat = a
        else:
            paths.append(a)
    if pat is None or not paths:
        sys.stderr.write("usage: pygrep_std [-r] [-i] PATTERN PATH...\n")
        return 2

    patb = pat.encode("utf-8", "surrogateescape")
    lpat = patb.translate(_LOWER)
    multi = r or len(paths) > 1

    out_list = []
    # use a list as the accumulator, join once at the end (batched output)
    matched = False
    for p in paths:
        pb = p.encode("utf-8", "surrogateescape")
        try:
            st = os.stat(pb)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            if r and walk(pb, patb, lpat, ci, multi, out_list):
                matched = True
        elif stat.S_ISREG(st.st_mode):
            if search_file(pb, patb, lpat, ci, multi, out_list):
                matched = True

    if out_list:
        sys.stdout.buffer.write(b"".join(out_list))
    sys.stdout.buffer.flush()
    return 0 if matched else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
