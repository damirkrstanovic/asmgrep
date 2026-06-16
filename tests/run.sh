#!/usr/bin/env bash
# Correctness harness: compare asmgrep against `grep -F` (fixed strings, so the
# semantics line up with asmgrep's literal, regex-free matching).
#
# Cross-file output order is not guaranteed to match grep (both walk readdir
# order), so outputs are sorted before comparison. Exit codes are checked too.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASMGREP="$ROOT/asmgrep"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0

# ---- build a fixture tree ----
printf 'hello world\nHELLO there\ngoodbye\nwell hello\n'      > "$FIX/a.txt"
printf 'alpha\nfind ME here\nplain line\n'                    > "$FIX/b.txt"
printf 'regex chars: a.b a*b [x] (y)\nliteral a.b only\n'     > "$FIX/meta.txt"
printf 'no newline at end'                                    > "$FIX/nonl.txt"   # no trailing \n
mkdir -p "$FIX/sub/deep"
printf 'me too\nFIND me\nnothing\n'                           > "$FIX/sub/deep/c.txt"
printf 'just stuff\nme here as well\n'                        > "$FIX/sub/d.txt"
: > "$FIX/empty.txt"

# check NAME asmgrep-args... -- grep-args...
# Runs asmgrep with the args before `--`, grep -F with the args after, compares
# sorted stdout and exit codes.
check() {
  local name="$1"; shift
  local a=(); local g=()
  while [ "$1" != "--" ]; do a+=("$1"); shift; done
  shift
  g=("$@")

  local ao ae go ge
  ao="$("$ASMGREP" "${a[@]}" 2>/dev/null | sort)"; ae=$?
  go="$(grep -F "${g[@]}" 2>/dev/null | sort)";   ge=$?

  if [ "$ao" = "$go" ] && [ "$ae" -eq "$ge" ]; then
    pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL  %s\n' "$name"
    printf '      asmgrep exit=%s  grep exit=%s\n' "$ae" "$ge"
    diff <(printf '%s\n' "$go") <(printf '%s\n' "$ao") | sed 's/^/      /'
  fi
}

echo "fixtures: $FIX"
echo "running correctness cases..."

check "literal single file"        hello "$FIX/a.txt"                 -- hello "$FIX/a.txt"
check "case-insensitive"        -i hello "$FIX/a.txt"                 -- -i hello "$FIX/a.txt"
check "no match (exit 1)"          zzzz  "$FIX/a.txt"                 -- zzzz  "$FIX/a.txt"
check "match at line start"        alpha "$FIX/b.txt"                 -- alpha "$FIX/b.txt"
check "regex metachar a.b literal" "a.b" "$FIX/meta.txt"              -- "a.b" "$FIX/meta.txt"
check "regex metachar [x] literal" "[x]" "$FIX/meta.txt"             -- "[x]" "$FIX/meta.txt"
check "no trailing newline"        newline "$FIX/nonl.txt"            -- newline "$FIX/nonl.txt"
check "empty file"                 anything "$FIX/empty.txt"          -- anything "$FIX/empty.txt"
check "multi-file prefix"          me "$FIX/sub/deep/c.txt" "$FIX/sub/d.txt" -- me "$FIX/sub/deep/c.txt" "$FIX/sub/d.txt"
check "recursive -r"            -r me "$FIX"                          -- -r me "$FIX"
check "recursive -ri"          -ri find "$FIX"                        -- -ri find "$FIX"
check "recursive no match"     -r    qqqq "$FIX"                      -- -r qqqq "$FIX"
check "empty pattern matches all"  "" "$FIX/a.txt"                    -- "" "$FIX/a.txt"

# ---- parallel path: a tree large enough to trigger multithreading ----
# (output order is unspecified when parallel, so compare as a sorted set)
BIGTREE="$FIX/many"
mkdir -p "$BIGTREE"
for i in $(seq 1 300); do
  printf 'line one error here\nplain %d\nanother Error %d\n' "$i" "$i" > "$BIGTREE/f$i.txt"
done
ao="$("$ASMGREP" -ri error "$BIGTREE" 2>/dev/null | sort)"
go="$(grep -rIiF -- error "$BIGTREE" 2>/dev/null | sort)"
if [ "$ao" = "$go" ]; then
  pass=$((pass+1)); printf '  ok   parallel tree (300 files, set == grep)\n'
else
  fail=$((fail+1)); printf 'FAIL  parallel tree\n'
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
