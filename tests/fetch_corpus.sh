#!/usr/bin/env bash
# Fetch / verify the pinned benchmark corpus (tests/corpus.lock) so the numbers
# are reproducible: every run sees the same repos at the same commits.
#
#   tests/fetch_corpus.sh            verify; clone any missing repo at its pinned SHA
#   tests/fetch_corpus.sh --pin      ALSO `git checkout <sha>` repos sitting on another commit
#                                    (only touches working trees when you ask for it)
#   CORPUS_DIR=/path tests/fetch_corpus.sh     where the checkouts live (default /home/damirk/src)
#
# Clones use a blobless partial clone (--filter=blob:none) so even openjdk is cheap.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/tests/corpus.lock"
CORPUS_DIR="${CORPUS_DIR:-/home/damirk/src}"
PIN=0; [ "${1:-}" = "--pin" ] && PIN=1

[ -f "$LOCK" ] || { echo "missing $LOCK"; exit 1; }
mkdir -p "$CORPUS_DIR"

ok=0; miss=0; drift=0
printf '%-14s %-10s %s\n' REPO STATUS DETAIL
printf -- '-------------------------------------------------------------\n'

# strip comments/blank lines, read name url sha
while read -r name url sha _rest; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue;; esac
  dir="$CORPUS_DIR/$name"

  if [ ! -d "$dir/.git" ]; then
    printf '%-14s %-10s %s\n' "$name" "CLONING" "$url"
    if git clone --filter=blob:none --no-checkout "$url" "$dir" >/dev/null 2>&1 \
       && git -C "$dir" checkout -q "$sha" 2>/dev/null; then
      printf '%-14s %-10s %s\n' "$name" "OK" "cloned @ ${sha:0:11}"; ok=$((ok+1))
    else
      printf '%-14s %-10s %s\n' "$name" "FAIL" "clone/checkout failed"; miss=$((miss+1))
    fi
    continue
  fi

  cur="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if [ "$cur" = "$sha" ]; then
    printf '%-14s %-10s %s\n' "$name" "OK" "pinned @ ${sha:0:11}"; ok=$((ok+1))
  elif [ "$PIN" = 1 ]; then
    # fetch the exact object if we don't have it, then check it out
    git -C "$dir" cat-file -e "$sha" 2>/dev/null || git -C "$dir" fetch -q --filter=blob:none origin "$sha" 2>/dev/null
    if git -C "$dir" checkout -q "$sha" 2>/dev/null; then
      printf '%-14s %-10s %s\n' "$name" "PINNED" "checked out ${sha:0:11}"; ok=$((ok+1))
    else
      printf '%-14s %-10s %s\n' "$name" "DRIFT" "want ${sha:0:11} have ${cur:0:11} (checkout failed)"; drift=$((drift+1))
    fi
  else
    printf '%-14s %-10s %s\n' "$name" "DRIFT" "have ${cur:0:11}, want ${sha:0:11}  (re-run with --pin)"; drift=$((drift+1))
  fi
done < "$LOCK"

printf -- '-------------------------------------------------------------\n'
echo "corpus dir: $CORPUS_DIR   ok=$ok  missing/failed=$miss  drift=$drift"
[ "$drift" -gt 0 ] && [ "$PIN" = 0 ] && echo "note: $drift repo(s) on a different commit — numbers won't match the pinned corpus until you run with --pin"
[ $((miss+drift)) -eq 0 ] && echo "corpus is pinned and ready." || true
