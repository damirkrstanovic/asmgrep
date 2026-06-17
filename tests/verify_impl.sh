#!/usr/bin/env bash
# Per-implementation correctness harness: compare ANY grep-clone binary against
# `grep -F` (fixed strings == this project's literal, regex-free semantics).
#
# Usage: tests/verify_impl.sh /path/to/binary [/path/to/binary ...]
# Exit 0 iff every binary passes every case. Outputs are sorted before compare
# (cross-file order is unspecified for the parallel implementations).
set -u

GREP=/usr/bin/grep
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ---- fixture tree (mirrors tests/run.sh) ----
printf 'hello world\nHELLO there\ngoodbye\nwell hello\n'  > "$FIX/a.txt"
printf 'alpha\nfind ME here\nplain line\n'                > "$FIX/b.txt"
printf 'regex chars: a.b a*b [x] (y)\nliteral a.b only\n' > "$FIX/meta.txt"
printf 'no newline at end'                                > "$FIX/nonl.txt"
mkdir -p "$FIX/sub/deep"
printf 'me too\nFIND me\nnothing\n'                       > "$FIX/sub/deep/c.txt"
printf 'just stuff\nme here as well\n'                    > "$FIX/sub/d.txt"
: > "$FIX/empty.txt"
printf 'text before\x00binary after\nerror here\n'        > "$FIX/bin.dat"   # NUL => binary, skipped
BIG="$FIX/many"; mkdir -p "$BIG"
for i in $(seq 1 300); do
  printf 'line one error here\nplain %d\nanother Error %d\n' "$i" "$i" > "$BIG/f$i.txt"
done

tot_pass=0; tot_fail=0

# check BIN NAME -- bin-args... :: grep-args...
check() {
  local bin="$1" name="$2"; shift 2
  local a=(); local g=()
  while [ "$1" != "::" ]; do a+=("$1"); shift; done
  shift; g=("$@")
  local bo be go ge
  bo="$("$bin" "${a[@]}" 2>/dev/null | sort)"; be=$?
  go="$("$GREP" -F "${g[@]}" 2>/dev/null | sort)"; ge=$?
  if [ "$bo" = "$go" ] && [ "$be" -eq "$ge" ]; then
    tot_pass=$((tot_pass+1)); printf '    ok   %s\n' "$name"
  else
    tot_fail=$((tot_fail+1))
    printf '    FAIL %s  (bin exit=%s grep exit=%s)\n' "$name" "$be" "$ge"
    diff <(printf '%s\n' "$go") <(printf '%s\n' "$bo") | sed 's/^/         /' | head -8
  fi
}

run_one() {
  local bin="$1"
  printf '== %s ==\n' "$bin"
  check "$bin" "literal single file"   hello "$FIX/a.txt"        :: hello "$FIX/a.txt"
  check "$bin" "case-insensitive"   -i hello "$FIX/a.txt"        :: -i hello "$FIX/a.txt"
  check "$bin" "no match (exit 1)"     zzzz  "$FIX/a.txt"        :: zzzz  "$FIX/a.txt"
  check "$bin" "match at line start"   alpha "$FIX/b.txt"        :: alpha "$FIX/b.txt"
  check "$bin" "metachar a.b literal"  "a.b" "$FIX/meta.txt"     :: "a.b" "$FIX/meta.txt"
  check "$bin" "metachar [x] literal"  "[x]" "$FIX/meta.txt"     :: "[x]" "$FIX/meta.txt"
  check "$bin" "no trailing newline"   newline "$FIX/nonl.txt"   :: newline "$FIX/nonl.txt"
  check "$bin" "empty file"            anything "$FIX/empty.txt" :: anything "$FIX/empty.txt"
  check "$bin" "multi-file prefix"     me "$FIX/sub/deep/c.txt" "$FIX/sub/d.txt" :: me "$FIX/sub/deep/c.txt" "$FIX/sub/d.txt"
  check "$bin" "recursive -r"       -r me "$FIX/sub"             :: -r me "$FIX/sub"
  check "$bin" "recursive -ri"     -ri find "$FIX/sub"           :: -ri find "$FIX/sub"
  check "$bin" "recursive no match" -r qqqq "$FIX/sub"           :: -r qqqq "$FIX/sub"
  check "$bin" "empty pattern all"     "" "$FIX/a.txt"           :: "" "$FIX/a.txt"
  check "$bin" "empty pat empty file"  "" "$FIX/empty.txt"       :: "" "$FIX/empty.txt"
  check "$bin" "binary skip (NUL)"  -r error "$FIX/bin.dat"      :: -rI error "$FIX/bin.dat"
  # parallel-path stress: 300-file tree, set-equality vs grep
  local bo go
  bo="$("$bin" -ri error "$BIG" 2>/dev/null | sort)"
  go="$("$GREP" -rIiF -- error "$BIG" 2>/dev/null | sort)"
  if [ "$bo" = "$go" ]; then tot_pass=$((tot_pass+1)); printf '    ok   parallel tree (300 files)\n'
  else tot_fail=$((tot_fail+1)); printf '    FAIL parallel tree (300 files)\n'; fi
}

[ $# -gt 0 ] || { echo "usage: $0 BINARY [BINARY ...]"; exit 2; }
for b in "$@"; do
  if [ ! -x "$b" ]; then printf '== %s ==\n    SKIP (not executable / missing)\n' "$b"; tot_fail=$((tot_fail+1)); continue; fi
  run_one "$b"
done
echo "----------------------------------------"
echo "passed: $tot_pass   failed: $tot_fail"
[ "$tot_fail" -eq 0 ]
