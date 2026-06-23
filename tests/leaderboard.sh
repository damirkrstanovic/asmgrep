#!/usr/bin/env bash
# Generate the ×grep leaderboard: every language implementation (best shipped
# variant) vs GNU grep, across the pinned corpus (tests/corpus.lock).
#
#   tests/leaderboard.sh [PATTERN] [repo ...]
#   TIMEOUT=300  per-(impl,repo) wall-clock cap (s); repos that exceed it are
#                EXCLUDED from that impl's geomean and marked 'slow:<repo>'.
#   CORPUS_DIR=/home/damirk/src   where the pinned checkouts live
#   BINS="a b c"  explicit binary basenames (default: best variant per language)
#
# Result counts only if its match-line count equals GNU grep's (correctness gate).
# ×grep = geomean over completed repos of mean(impl)/mean(grep). See docs/BENCHMARKING.md.
#
# Timing: fast (impl,repo) pairs (probe < 3 s) get hyperfine precision (warmup1, M5);
# slow ones use a single bounded run so a 4-minute scan isn't run 6×. Total + per-impl
# wall-clock is reported at the end.
set -u
# Byte-level matching for grep (the correctness gate + timing baseline): our impls
# read raw bytes, so the reference must too. UTF-8-locale grep -i skips matches near
# invalid-UTF-8 bytes (e.g. jdk's tradChinese.po) and would spuriously fail the gate.
# Impls read bytes regardless of locale, so they're unaffected. See docs/BENCHMARKING.md.
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
CORPUS_DIR="${CORPUS_DIR:-/home/damirk/src}"
LOCK="$ROOT/tests/corpus.lock"
GREP=/usr/bin/grep
TIMEOUT="${TIMEOUT:-300}"
HFAST=3.0   # probe seconds under which we use hyperfine for precision
PAT="${1:-error}"; [ $# -gt 0 ] && shift
command -v hyperfine >/dev/null || { echo "hyperfine required"; exit 1; }

REPOS=("$@")
if [ "${#REPOS[@]}" -eq 0 ]; then
  mapfile -t REPOS < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$LOCK" | awk '{print $1}')
fi

now() { date +%s.%N; }
elapsed() { python3 -c "print('%.3f'%($2-$1))"; }

# known-broken on real corpora (hangs / wrong counts) -- skipped here, recorded as FAILED elsewhere
SKIP_BINS="${SKIP_BINS:-forthgrep_std}"
skip() { case " $SKIP_BINS " in *" $1 "*) return 0;; *) return 1;; esac; }

pick_bins() {
  local f key best v
  declare -A seen=()
  for v in asmgrep cgrep zgrep gogrep gogrep_mt rustgrep; do { [ -x "$BIN/$v" ] && ! skip "$v"; } && echo "$v"; done
  # Derive each language's key from ANY built variant (not just the base _std):
  # Java ships only _mt/_mt_tuned, and C# names its binary csgrep_aot_std (the
  # _aot_ infix dodges a bare *grep_std glob) -- both were silently dropped before.
  for f in "$BIN"/*grep_std "$BIN"/*grep_std_mt "$BIN"/*grep_std_mt_tuned "$BIN"/*grep_aot_std*; do
    [ -e "$f" ] || continue
    key="$(basename "$f")"
    key="${key%_std_mt_tuned}"; key="${key%_std_mt}"; key="${key%_std}"
    [ -n "${seen[$key]:-}" ] && continue
    seen[$key]=1
    best=""
    for v in "${key}_std_mt_tuned" "${key}_std_mt" "${key}_std"; do
      { [ -x "$BIN/$v" ] && ! skip "$v"; } && { best="$v"; break; }
    done
    [ -n "$best" ] && echo "$best"
  done
}
if [ -n "${BINS:-}" ]; then read -ra BINLIST <<<"$BINS"; else mapfile -t BINLIST < <(pick_bins); fi

RUN_START=$(now)
echo "# leaderboard run  $(date '+%Y-%m-%d %H:%M:%S')"
echo "# corpus: ${REPOS[*]}"
echo "# impls: ${#BINLIST[@]}   timeout: ${TIMEOUT}s   governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
echo

# --- GNU grep baseline once per repo (the shared denominator) + a tiny startup file
declare -A GREP_MS REPO_OK
SMALLFILE=""
echo "# timing GNU grep baseline per repo..."
for repo in "${REPOS[@]}"; do
  dir="$CORPUS_DIR/$repo"
  [ -d "$dir" ] || { echo "#   skip $repo (missing under $CORPUS_DIR)"; continue; }
  REPO_OK[$repo]=1
  [ -z "$SMALLFILE" ] && SMALLFILE="$(find "$dir" -type f -size +1k -size -8k 2>/dev/null | head -1)"
  hyperfine --warmup 2 -M 10 -N --ignore-failure "$GREP -rIiF $PAT $dir" --export-json /tmp/_lbg.json >/dev/null 2>&1
  GREP_MS[$repo]=$(python3 -c "import json;print('%.3f'%(json.load(open('/tmp/_lbg.json'))['results'][0]['mean']*1000))" 2>/dev/null)
  echo "#   grep $repo = ${GREP_MS[$repo]} ms"
done
echo

declare -A IMPL_SECS
RESULT_FILE="$(mktemp)"
OUTF="$(mktemp)"; trap 'rm -f "$OUTF" "$RESULT_FILE"' EXIT
for b in "${BINLIST[@]}"; do
  [ -x "$BIN/$b" ] || continue
  bt0=$(now); logsum=0; n=0; notes=""
  for repo in "${REPOS[@]}"; do
    [ "${REPO_OK[$repo]:-0}" = 1 ] || continue
    dir="$CORPUS_DIR/$repo"
    # one bounded run: correctness gate + probe timing (warms cache)
    # write to a temp file, NOT a pipe: when timeout kills an impl that spawned
    # children (raku/MoarVM), a surviving child holding a pipe's write-end blocks
    # `wc -l` forever (this is what made one run take 6.85 h). A file never blocks.
    p0=$(now)
    timeout -k 10 "$TIMEOUT" "$BIN/$b" -r -i "$PAT" "$dir" >"$OUTF" 2>/dev/null; rc=$?
    p1=$(now)
    ic=$(wc -l < "$OUTF")
    # timed out (SIGTERM 124 / SIGKILL 137). corpus is size-ordered, so a bigger
    # repo can only be slower (or hang the same way) — abort the rest for this impl.
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      pkill -9 -f "$dir" 2>/dev/null   # reap any orphaned worker still scanning this repo
      notes+=" slow:$repo(+skipped larger)"; break
    fi
    gc=$($GREP -rIiF -- "$PAT" "$dir" 2>/dev/null | wc -l)
    if [ "$ic" != "$gc" ]; then notes+=" ≠grep:$repo"; continue; fi
    probe=$(elapsed "$p0" "$p1")
    if python3 -c "import sys;sys.exit(0 if $probe < $HFAST else 1)"; then
      # fast → hyperfine for precision. MUST be timeout-wrapped: an impl that
      # hangs here (e.g. Dyalog sporadically spawning a Chromium HTMLRenderer
      # that never exits) would otherwise block the whole run indefinitely —
      # the probe run above is bounded, but hyperfine was not.
      timeout -k 10 "$TIMEOUT" hyperfine --warmup 1 -M 5 -N --ignore-failure "$BIN/$b -r -i $PAT $dir" --export-json /tmp/_lbi.json >/dev/null 2>&1
      im=$(python3 -c "import json;print('%.3f'%(json.load(open('/tmp/_lbi.json'))['results'][0]['mean']*1000))" 2>/dev/null)
    else
      # slow → use the single bounded run we already paid for
      im=$(python3 -c "print('%.3f'%($probe*1000))")
    fi
    gm="${GREP_MS[$repo]:-}"
    { [ -z "$im" ] || [ -z "$gm" ]; } && continue
    logsum=$(python3 -c "import math;print($logsum+math.log($im/$gm))")
    n=$((n+1))
  done
  su=""
  [ -n "$SMALLFILE" ] && { timeout -k 5 60 hyperfine --warmup 2 -M 8 -N --ignore-failure "$BIN/$b -r $PAT $SMALLFILE" --export-json /tmp/_lbs.json >/dev/null 2>&1 \
       && su=$(python3 -c "import json;print('%.1f'%(json.load(open('/tmp/_lbs.json'))['results'][0]['mean']*1000))" 2>/dev/null); }
  # Reap stragglers this impl left detached so they can't contend with the next
  # impl's timing. Dyalog forks Chromium HTMLRenderer daemons (under /opt/mdyalog)
  # that survive `timeout`'s child-kill; targeted so nothing else is affected.
  pkill -9 -f "/opt/mdyalog" 2>/dev/null
  pkill -9 -f "grep_std.apls" 2>/dev/null
  bt1=$(now); IMPL_SECS[$b]=$(elapsed "$bt0" "$bt1")
  if [ "$n" -gt 0 ]; then
    xg=$(python3 -c "import math;print('%.2f'%math.exp($logsum/$n))")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$xg" "$b" "${su:-?}" "$n/${#REPOS[@]}" "${IMPL_SECS[$b]}" "$notes" >> "$RESULT_FILE"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "99999" "$b" "${su:-?}" "0/${#REPOS[@]}" "${IMPL_SECS[$b]}" "${notes:- (none completed)}" >> "$RESULT_FILE"
  fi
  printf '  done %-26s xgrep=%s  %ss\n' "$b" "$(tail -1 "$RESULT_FILE" | cut -f1)" "${IMPL_SECS[$b]}" >&2
done

RUN_END=$(now); TOTAL=$(elapsed "$RUN_START" "$RUN_END")
echo
printf '%-26s %9s %8s %9s %8s  %s\n' IMPL xgrep startup repos secs notes
printf -- '--------------------------------------------------------------------------------------\n'
sort -t$'\t' -k1 -g "$RESULT_FILE" | while IFS=$'\t' read -r xg b su rr secs notes; do
  [ "$xg" = "99999" ] && xg="—"
  printf '%-26s %8sx %6sms %9s %7ss  %s\n' "$b" "$xg" "$su" "$rr" "$secs" "$notes"
done
rm -f "$RESULT_FILE"
echo "--------------------------------------------------------------------------------------"
printf 'pattern=%q  corpus=%d repos  timeout=%ss  baseline=GNU grep (-rIiF)\n' "$PAT" "${#REPOS[@]}" "$TIMEOUT"
echo "grep baseline (ms): $(for r in "${REPOS[@]}"; do printf '%s=%s ' "$r" "${GREP_MS[$r]:-NA}"; done)"
printf 'TOTAL WALL-CLOCK: %s s  (%.1f min)\n' "$TOTAL" "$(python3 -c "print($TOTAL/60)")"
echo "×grep = geomean(mean_impl/mean_grep) over completed repos; <1 = faster than grep. See docs/BENCHMARKING.md"
