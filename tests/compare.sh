#!/usr/bin/env bash
# Three-way comparison: asmgrep vs GNU grep vs ripgrep, across real repositories.
#
# Two things are measured per repo:
#   1. CORRECTNESS - aligned flags so all three search the SAME file universe
#      (whole tree incl .git/hidden, skip binary, literal/fixed match). Match
#      counts must agree (asmgrep is the reference vs grep).
#   2. PERFORMANCE - hyperfine times the same aligned commands.
#
# Tools are invoked by absolute path to bypass the shell's `grep` function.
#
# Usage: tests/compare.sh [PATTERN] [repo ...]
#   PATTERN default: "error"   (literal, case-insensitive)
#   repos    default: a curated size-spread under /home/damirk/src
set -u
# Byte-level matching for ALL tools: our impls read raw bytes (literal grep -F
# semantics), so the reference must too. In a UTF-8 locale GNU grep's -i skips
# matches on lines with invalid-UTF-8 bytes (e.g. jdk's tradChinese.po), which
# would spuriously fail the correctness gate. LC_ALL=C makes grep/rg byte-exact
# (and a touch faster, uniformly). Impls are locale-independent, so unaffected.
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS_DIR="${CORPUS_DIR:-/home/damirk/src}"   # where the pinned checkouts live
LOCK="$ROOT/tests/corpus.lock"
ASM="$ROOT/bin/asmgrep"
GREP=/usr/bin/grep
RG=/usr/bin/rg
PAT="${1:-error}"; [ $# -gt 0 ] && shift

# default repo set = the pinned, reproducible corpus (tests/corpus.lock);
# override by passing repo names as args. Run tests/fetch_corpus.sh first.
REPOS=("$@")
if [ "${#REPOS[@]}" -eq 0 ]; then
  mapfile -t REPOS < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$LOCK" | awk '{print $1}')
fi

# aligned invocations (same file set, skip binary, case-insensitive fixed string)
asm_cmd()  { "$ASM" -ri "$PAT" "$1"; }
grep_cmd() { "$GREP" -rIiF -- "$PAT" "$1"; }
rg_cmd()   { "$RG" -uuiF --no-heading -N --color never -- "$PAT" "$1"; }

command -v hyperfine >/dev/null || { echo "hyperfine required"; exit 1; }
[ -x "$ASM" ] || (cd "$ROOT" && make >/dev/null)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%-18s %9s %8s %8s %8s   %7s %7s %7s   %8s %8s\n' \
  REPO SIZE asmN grepN rgN asm_ms grep_ms rg_ms 'vs_grep' 'vs_rg'
echo "---------------------------------------------------------------------------------------------------"

# accumulate log-speedups for geometric means
sum_g=0; sum_r=0; cnt=0; mism=0

for repo in "${REPOS[@]}"; do
  dir="$CORPUS_DIR/$repo"
  [ -d "$dir" ] || { printf '%-18s  (missing)\n' "$repo"; continue; }
  size=$(du -sh "$dir" 2>/dev/null | cut -f1)

  # correctness: match-line counts (sorted-set comparison for asm vs grep)
  aN=$(asm_cmd "$dir" 2>/dev/null | wc -l)
  gN=$(grep_cmd "$dir" 2>/dev/null | wc -l)
  rN=$(rg_cmd "$dir" 2>/dev/null | wc -l)
  flag=""
  if [ "$aN" != "$gN" ]; then
    flag=" !asm≠grep"; mism=$((mism+1))
    diff <(asm_cmd "$dir" 2>/dev/null|sort) <(grep_cmd "$dir" 2>/dev/null|sort) > "$TMP/$repo.diff"
  fi

  # performance
  hyperfine --warmup 2 -M 12 -N --ignore-failure --export-json "$TMP/$repo.json" \
    --command-name asmgrep "$ASM -ri $PAT $dir" \
    --command-name grep    "$GREP -rIiF $PAT $dir" \
    --command-name rg      "$RG -uuiF --no-heading -N --color never $PAT $dir" \
    >/dev/null 2>&1

  read am gm rm <<<"$(python3 - "$TMP/$repo.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))["results"]
m={r["command"]:r["mean"]*1000 for r in d}
print(f'{m["asmgrep"]:.2f} {m["grep"]:.2f} {m["rg"]:.2f}')
PY
)"
  vg=$(python3 -c "print(f'{$gm/$am:.2f}x')")
  vr=$(python3 -c "print(f'{$rm/$am:.2f}x')")
  sum_g=$(python3 -c "import math;print($sum_g+math.log($gm/$am))")
  sum_r=$(python3 -c "import math;print($sum_r+math.log($rm/$am))")
  cnt=$((cnt+1))

  printf '%-18s %9s %8s %8s %8s   %7s %7s %7s   %8s %8s%s\n' \
    "$repo" "$size" "$aN" "$gN" "$rN" "$am" "$gm" "$rm" "$vg" "$vr" "$flag"
done

echo "---------------------------------------------------------------------------------------------------"
python3 -c "import math;print(f'geomean speedup  asmgrep vs grep = {math.exp($sum_g/$cnt):.2f}x   asmgrep vs rg = {math.exp($sum_r/$cnt):.2f}x   ({$cnt} repos)')"
echo "pattern='$PAT' (case-insensitive, fixed-string); aligned flags = whole tree incl .git, skip binary."
[ "$mism" -gt 0 ] && echo "NOTE: $mism repo(s) where asmgrep≠grep counts (diffs saved); usually binary-detection edge cases."
echo "(positive 'vs' = asmgrep faster)"
