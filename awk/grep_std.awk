# awkgrep_std - idiomatic GNU awk: readdir-walked recursion + whole-file read +
# index() literal substring scan. Single-threaded (gawk has no threads, no
# shared-memory concurrency, no native dir API beyond the bundled extensions) --
# so this is the ONLY variant. That gawk is _std-only is itself a finding: a
# text-processing DSL built for exactly this scan, with no concurrency pillar.
#
#   gawk -f grep_std.awk -- [-r] [-i] PATTERN PATH...
#
# Literal (fixed-string) substring search, regex-free: index(hay,needle).
# Binary skip: NUL in the first 64KB => skip whole file (like grep -I).
# Output: "path:line" when -r or multiple paths, else "line".

@load "readdir"
@load "filefuncs"

# Read an entire file into a single string, bytes preserved (incl. NUL).
# Returns the content; sets HAVE to 1 on success, 0 on open failure.
function slurp(path,   data, chunk, save_rs, ok) {
    save_rs = RS
    RS = "\x01"                    # rare byte; getline returns chunks split on it
    data = ""
    HAVE = 0
    while ((getline chunk < path) > 0) {
        data = data chunk RT       # RT is the matched separator (or "" at EOF)
        HAVE = 1
    }
    close(path)
    RS = save_rs
    return data
}

function search_file(path,   data, peek, hay, ndl, n, lines, i, last_nl, line, lim) {
    data = slurp(path)
    if (!HAVE) return              # open failed / empty -> nothing to print
    if (length(data) == 0) return

    # binary skip: NUL within first 64KB
    peek = (length(data) > 65536) ? substr(data, 1, 65536) : data
    if (index(peek, "\0") > 0) return

    hay = data
    ndl = PAT
    if (CI) { hay = tolower(data); ndl = LPAT }

    # split into lines; a trailing "\n" yields a trailing empty field we must drop.
    last_nl = (substr(data, length(data), 1) == "\n")
    n = split(data, lines, "\n")
    lim = last_nl ? n - 1 : n       # if file ends in \n, ignore phantom last field

    for (i = 1; i <= lim; i++) {
        # CI: compare lowercased copy of this line, but print the original.
        if (CI)  line = tolower(lines[i])
        else     line = lines[i]
        if (index(line, ndl) > 0) {
            MATCHED = 1
            if (MULTI) printf "%s:%s\n", path, lines[i]
            else       print lines[i]
        }
    }
}

# Recursive directory walk via readdir. Manage our own stack of dirs; skip
# symlinks (don't follow). readdir lines are "inode/name/type"; name has no '/'.
function walk(dir,   line, ino, rest, name, type, slash, child) {
    while ((getline line < dir) > 0) {
        slash = index(line, "/")
        rest = substr(line, slash + 1)          # "name/type"
        slash = length(rest)                    # find LAST '/'; type is 1 char
        # type is the final field after the last '/'
        type = substr(rest, length(rest), 1)
        name = substr(rest, 1, length(rest) - 2)
        if (name == "." || name == "..") continue
        child = dir "/" name
        if (type == "d") {
            walk(child)
        } else if (type == "f") {
            search_file(child)
        } else if (type == "u") {
            # type unknown on some filesystems: lstat to classify without
            # following symlinks (readdir already reports "l" for symlinks).
            delete st
            if (lstat(child, st) == 0) {
                if (st["type"] == "directory") walk(child)
                else if (st["type"] == "file") search_file(child)
            }
        }
        # type "l" (symlink) is intentionally skipped: we don't follow them.
    }
    close(dir)
}

BEGIN {
    CI = 0; R = 0; MATCHED = 0; MULTI = 0
    np = 0; no_more = 0; PAT = ""; have_pat = 0
    # parse ARGV ourselves (everything after `--` is verbatim).
    for (ai = 1; ai < ARGC; ai++) {
        a = ARGV[ai]
        if (!no_more && substr(a, 1, 1) == "-" && length(a) > 1) {
            if (a == "--") { no_more = 1; continue }
            for (ci = 2; ci <= length(a); ci++) {
                c = substr(a, ci, 1)
                if (c == "i") CI = 1
                else if (c == "r") R = 1
                else { print "usage: awkgrep_std [-r] [-i] PATTERN PATH..." > "/dev/stderr"; exit 2 }
            }
        } else if (!have_pat) {
            PAT = a; have_pat = 1
        } else {
            np++; PATHS[np] = a
        }
    }
    if (!have_pat || np == 0) {
        print "usage: awkgrep_std [-r] [-i] PATTERN PATH..." > "/dev/stderr"
        exit 2
    }
    LPAT = tolower(PAT)
    MULTI = (R || np > 1)

    for (pi = 1; pi <= np; pi++) {
        p = PATHS[pi]
        delete st
        if (stat(p, st) != 0) continue          # missing / unreadable: skip
        if (st["type"] == "directory") {
            if (R) walk(p)
            # a directory without -r: grep warns & skips; we just skip.
        } else if (st["type"] == "file") {
            search_file(p)
        }
        # other top-level types (symlink to dir, fifo, ...) are skipped.
    }
    exit (MATCHED ? 0 : 1)
}
