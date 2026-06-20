Red [
    Title:   "redgrep_std"
    Purpose: {The Red (Rebol-family, homoiconic) entry in the asmgrep experiment.
              Literal-substring grep: read/binary + find scan + manual recursion.
              Red 0.6.6 is an interpreted, single-threaded toolchain with no
              concurrency story -- so, like gawk, it ships _std only (the missing
              _mt is itself the finding).}
]

; Red sets the current dir to the SCRIPT's directory, not where the launcher was
; invoked -- restore the shell cwd so relative path args resolve like every other
; impl. (Test/benchmark paths are absolute, but this keeps it correct generally.)
attempt [change-dir to-file get-env "PWD"]

; ---- arg parse ----
; Red 0.6.6's system/options/args mis-splits empty/odd arguments (it reads the
; NUL-separated /proc/self/cmdline and collapses empty fields), which corrupts
; e.g. `grep "" file`. Parse the cmdline ourselves, preserving empty fields, then
; drop the interpreter + script-path tokens.
split-nul: function [b [binary!]] [
    res: make block! 8
    start: b
    cur:   b
    while [not tail? cur] [
        either zero? cur/1 [
            append res to-string copy/part start cur
            cur: next cur
            start: cur
        ][cur: next cur]
    ]
    append res to-string copy/part start cur
    res
]
argv: split-nul read/binary %/proc/self/cmdline
if all [not empty? argv  empty? last argv] [take/last argv]   ; trailing-NUL field
args: either 2 <= length? argv [skip argv 2] [make block! 0]  ; drop red + script

recurse: false
ci:      false
no-more: false
pat:     none
paths:   make block! 8
foreach a args [
    either all [not no-more  string? a  1 < length? a  #"-" = a/1] [
        either a = "--" [no-more: true] [
            foreach c next a [
                case [
                    c = #"i" [ci: true]
                    c = #"r" [recurse: true]
                    true     [quit/return 2]            ; unknown flag
                ]
            ]
        ]
    ][
        either none? pat [pat: a] [append paths a]
    ]
]
if any [none? pat  empty? paths] [quit/return 2]
multi: any [recurse  1 < length? paths]

; ---- ASCII-only lowercase fold (lowercase does NOT work on binary! in Red) ----
fold: function [b [binary!]] [
    acc: make binary! length? b
    foreach byte b [
        append acc either all [byte >= 65  byte <= 90] [byte + 32] [byte]
    ]
    acc
]

patb:     to-binary pat
lpatb:    either ci [fold patb] [patb]
out:      make binary! 65536
matched?: false

; NB: Red words are CASE-INSENSITIVE, so a global `NL` would collide with the
; local `nl:` set-word below and get auto-localized to an unset `none` inside the
; function -- so we inline the newline byte #{0A} everywhere instead.
emit: function [path [string!] line [binary!]] [
    if multi [append out to-binary path  append out #{3A}]   ; "path:"
    append out line
    append out #{0A}
]

scan-file: function [path [string!]] [
    data: attempt [read/binary to-file path]
    if any [none? data  empty? data] [exit]
    ; binary skip: a NUL byte in the first 64 KB
    peek: either 65536 < length? data [copy/part data 65536] [data]
    if find peek #{00} [exit]
    either empty? patb [
        ; empty pattern -> every line, once (no phantom line after a final \n)
        p: data
        while [not tail? p] [
            nlp: find p #{0A}
            le: either nlp [nlp] [tail data]
            emit path copy/part p le
            set 'matched? true
            unless nlp [break]
            p: next le
        ]
    ][
        hay:    either ci [fold data] [data]
        needle: lpatb
        pos:    hay
        forever [
            found: find pos needle
            unless found [break]
            off:  index? found                  ; 1-based; same offset in data
            dpos: at data off
            lsr:  find/reverse dpos #{0A}
            ls:   either lsr [next lsr] [head data]
            ler:  find dpos #{0A}
            le:   either ler [ler] [tail data]
            emit path copy/part ls le
            set 'matched? true
            either le = tail data [break] [pos: at hay (1 + index? le)]
        ]
    ]
]

is-dir?: function [p [string!]] [block? attempt [read to-file rejoin [p "/"]]]

walk: function [dir [string!]] [
    entries: attempt [read to-file rejoin [dir "/"]]
    unless entries [exit]
    foreach e entries [
        nm: to-string e
        either #"/" = last nm [
            walk rejoin [dir "/" copy/part nm (length? nm) - 1]   ; subdir
        ][
            scan-file rejoin [dir "/" nm]
        ]
    ]
]

foreach p paths [
    either is-dir? p [if recurse [walk p]] [scan-file p]
]

unless empty? out [write/binary %/dev/stdout out]
quit/return either matched? [0] [1]
