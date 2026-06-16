#!/usr/bin/env bash
# Performance harness using hyperfine. Compares asmgrep vs `grep -F` and checks
# they report the same number of matching lines. Requires: hyperfine, awk.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASMGREP="$ROOT/bin/asmgrep"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

have_hf=1; command -v hyperfine >/dev/null || have_hf=0

bench() {  # bench LABEL  asmflags... -- pattern -- path
  local label="$1"; shift
  local af=(); while [ "$1" != "--" ]; do af+=("$1"); shift; done; shift
  local pat="$1"; shift; shift   # drop pattern and the following --
  local path="$1"
  # correctness: match counts must agree
  local ac gc
  ac=$("$ASMGREP" "${af[@]}" "$pat" "$path" 2>/dev/null | wc -l)
  gc=$(grep -F "${af[@]}" -- "$pat" "$path" 2>/dev/null | wc -l)
  local tag="matches=OK($ac)"; [ "$ac" = "$gc" ] || tag="MISMATCH(asm=$ac grep=$gc)"
  echo "## $label   [$tag]"
  if [ "$have_hf" = 1 ]; then
    hyperfine --warmup 3 -N --ignore-failure \
      --command-name asmgrep "$ASMGREP ${af[*]} $pat $path" \
      --command-name grep    "grep -F ${af[*]} $pat $path" 2>/dev/null \
      | grep -E 'Time|ran|faster'
  else
    echo "  (install hyperfine for timings)"
  fi
  echo
}

# Big single file: ~1.5M lines, needle on ~1 in 1000 lines.
BIG="$WORK/big.txt"
awk 'BEGIN{for(i=0;i<1500000;i++){if(i%1000==0)print "line " i " contains NEEDLE here"; else print "line " i " ordinary filler text payload"}}' > "$BIG"
echo "### single big file ($(du -h "$BIG"|cut -f1))"
bench "literal (rare byte)"     -- NEEDLE -- "$BIG"
bench "case-insensitive"     -i -- needle -- "$BIG"
bench "miss (must read all)"    -- ZZZZZZ -- "$BIG"

# Recursive tree of many small files + one big binary blob (exercises rg-style filtering).
TREE="$WORK/tree"
mkdir -p "$TREE"
for d in $(seq 0 19); do mkdir -p "$TREE/d$d"; for f in $(seq 0 49); do
  awk -v s="$d$f" 'BEGIN{for(i=0;i<200;i++){if(i==42)print "TARGET token " s; else print "filler row " i}}' > "$TREE/d$d/f$f.txt"
done; done
head -c 40000000 /dev/urandom > "$TREE/blob.bin"   # binary file to skip
echo "### recursive tree (1000 text files + 40MB binary blob)"
bench "recursive -r"  -r -- TARGET -- "$TREE"
