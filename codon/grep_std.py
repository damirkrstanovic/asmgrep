# codongrep_std - the Python loop-closer: Python-ish source, native binary.
# Codon (Exaloop LLVM-AOT) is a statically typed Python *subset* with its OWN
# stdlib -- NOT CPython. Mirrors python/grep_std.py semantics, byte-for-byte
# against `grep -F`.
#
# Codon caveats handled here (see Makefile note):
#   * Codon strings ARE raw byte arrays (open(p,"rb").read() -> str of bytes,
#     data[i] is a 1-byte str, ord() gives the byte). We never decode -- all
#     scanning is byte-exact on str.
#   * Codon's `os` stdlib is tiny: NO os.listdir / os.stat / os.path.isdir /
#     isfile / islink / os.scandir. We go straight to libc via `from C import`
#     (stat, lstat, opendir, readdir, closedir) and parse the structs by offset.
#   * Raw stdout: no sys.stdout.buffer; we libc write(2) the joined bytes.
import sys

from C import stat(cobj, cobj) -> i32 as c_stat
from C import lstat(cobj, cobj) -> i32 as c_lstat
from C import opendir(cobj) -> cobj as c_opendir
from C import readdir(cobj) -> cobj as c_readdir
from C import closedir(cobj) -> i32 as c_closedir
from C import strlen(cobj) -> int as c_strlen
from C import write(i32, cobj, int) -> int as c_write

# struct stat (glibc x86-64): st_mode is u32 at offset 24.
_ST_MODE_OFF = 24
_S_IFMT = 0xF000
_S_IFDIR = 0x4000
_S_IFREG = 0x8000
_S_IFLNK = 0xA000
# struct dirent (glibc): d_type u8 @18, d_name @19.
_D_TYPE_OFF = 18
_D_NAME_OFF = 19
_DT_UNKNOWN = 0
_DT_DIR = 4
_DT_REG = 8
_DT_LNK = 10


def _read_mode(buf: Ptr[byte]) -> int:
    b0 = int(buf[_ST_MODE_OFF]) & 0xFF
    b1 = int(buf[_ST_MODE_OFF + 1]) & 0xFF
    b2 = int(buf[_ST_MODE_OFF + 2]) & 0xFF
    b3 = int(buf[_ST_MODE_OFF + 3]) & 0xFF
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)


def _stat_mode(path: str, follow: bool) -> int:
    # returns st_mode, or -1 if the stat call failed.
    buf = Ptr[byte](256)
    if follow:
        r = c_stat(path.c_str(), buf)
    else:
        r = c_lstat(path.c_str(), buf)
    if int(r) != 0:
        return -1
    return _read_mode(buf)


def _lower(s: str) -> str:
    # ASCII-only fold: 'A'..'Z' -> +0x20, byte-exact, leaves the rest alone.
    out = List[byte](len(s))
    for i in range(len(s)):
        c = int(s.ptr[i]) & 0xFF
        if 65 <= c <= 90:
            c += 32
        out.append(byte(c))
    return str(out.arr.ptr, len(out))


def search_file(path: str, pat: str, lpat: str, ci: bool, multi: bool,
                out: List[str]) -> bool:
    try:
        data = open(path, "rb").read()
    except:
        return False
    n = len(data)
    if n == 0:
        return False
    # binary skip: NUL in first 64KB.
    peek_end = 65536 if n > 65536 else n
    if data.find("\x00", 0, peek_end) >= 0:
        return False

    if ci:
        hay = _lower(data)
        needle = lpat
    else:
        hay = data
        needle = pat

    matched = False
    pos = 0
    while pos <= n:
        m = hay.find(needle, pos)
        if m < 0:
            break
        # phantom empty line after a trailing newline.
        if m == n and n > 0 and (int(data.ptr[n - 1]) & 0xFF) == 0x0A:
            break
        ls = data.rfind("\n", 0, m) + 1
        le = data.find("\n", m)
        if le < 0:
            le = n
        matched = True
        if multi:
            out.append(path)
            out.append(":")
        out.append(data[ls:le])
        out.append("\n")
        pos = le + 1
    return matched


def walk(start: str, pat: str, lpat: str, ci: bool, multi: bool,
         out: List[str]) -> bool:
    matched = False
    stack = [start]
    while len(stack) > 0:
        d = stack.pop()
        dp = c_opendir(d.c_str())
        if dp == cobj():
            continue
        while True:
            e = c_readdir(dp)
            if e == cobj():
                break
            namep = e + _D_NAME_OFF
            name = str(namep, c_strlen(namep))
            if name == "." or name == "..":
                continue
            pe = Ptr[byte](e)
            dtype = int(pe[_D_TYPE_OFF]) & 0xFF
            full = d + "/" + name
            # Resolve type; fall back to lstat when the FS reports DT_UNKNOWN.
            is_lnk = dtype == _DT_LNK
            is_dir = dtype == _DT_DIR
            is_reg = dtype == _DT_REG
            if dtype == _DT_UNKNOWN:
                md = _stat_mode(full, False)
                if md < 0:
                    continue
                is_lnk = (md & _S_IFMT) == _S_IFLNK
                is_dir = (md & _S_IFMT) == _S_IFDIR
                is_reg = (md & _S_IFMT) == _S_IFREG
            if is_lnk:
                continue  # don't follow symlinks (grep -r)
            if is_dir:
                stack.append(full)
            elif is_reg:
                if search_file(full, pat, lpat, ci, multi, out):
                    matched = True
        c_closedir(dp)
    return matched


def usage():
    msg = "usage: codongrep_std [-r] [-i] PATTERN PATH...\n"
    c_write(i32(2), msg.ptr, len(msg))


def main(argv: List[str]) -> int:
    ci = False
    r = False
    pat = ""
    have_pat = False
    paths = List[str]()
    no_more = False
    for ai in range(1, len(argv)):
        a = argv[ai]
        if (not no_more) and len(a) > 0 and a[0] == "-" and a != "-":
            if a == "--":
                no_more = True
                continue
            for qi in range(1, len(a)):
                q = a[qi]
                if q == "i":
                    ci = True
                elif q == "r":
                    r = True
                else:
                    usage()
                    return 2
        elif not have_pat:
            pat = a
            have_pat = True
        else:
            paths.append(a)

    if (not have_pat) or len(paths) == 0:
        usage()
        return 2

    lpat = _lower(pat)
    multi = r or len(paths) > 1

    out = List[str]()
    matched = False
    for p in paths:
        md = _stat_mode(p, True)  # top-level: FOLLOW symlinks
        if md < 0:
            continue
        if (md & _S_IFMT) == _S_IFDIR:
            if r and walk(p, pat, lpat, ci, multi, out):
                matched = True
        elif (md & _S_IFMT) == _S_IFREG:
            if search_file(p, pat, lpat, ci, multi, out):
                matched = True

    if len(out) > 0:
        blob = "".join(out)
        c_write(i32(1), blob.ptr, len(blob))
    return 0 if matched else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
