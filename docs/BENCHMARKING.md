# Benchmarking — fair & repeatable

`grep` speed depends on the corpus, so a number like "3× faster than grep" is only
meaningful against a *named, pinned* corpus measured under controlled machine state.
This document is the contract behind every number in the README and RESULTS.md.

## The pinned corpus

`tests/corpus.lock` lists public repositories, each pinned to an **exact commit SHA**,
chosen as a size + file-count + language spread (the whole thesis turns on this:
small repos are *startup-dominated*, huge ones are *scan- and page-fault-dominated*):

| repo | src size | files | language | role |
|---|--:|--:|---|---|
| camilladsp | 2.1 MB | 145 | Rust | tiny — startup-dominated extreme |
| jellyfin | 20 MB | 2 464 | C# | small |
| navidrome | 21 MB | 1 841 | Go | small (README anchor) |
| onyx | 43 MB | 2 552 | Python/TS | medium |
| immich | 122 MB | 3 771 | TS | large (README anchor) |
| jdk | 809 MB | 70 779 | Java/C++ | huge — file-count / page-fault extreme |

Span: **~385× in bytes, ~488× in file count.** The small end makes process startup a
large share of wall-clock (why VM/JIT runtimes sink); the `jdk` end amortizes startup
and exposes the memory/parallelism pillars (per-file allocation, page-fault contention).

```sh
tests/fetch_corpus.sh          # clone any missing repo at its pinned SHA, verify the rest
tests/fetch_corpus.sh --pin    # also `git checkout <sha>` repos that drifted off the pin
CORPUS_DIR=/path tests/fetch_corpus.sh    # default /home/damirk/src
```

Editing the corpus = edit `tests/corpus.lock` (name, URL, SHA). Re-pin after a deliberate
bump by updating the SHA there.

## What is measured, and how it's kept fair

- **Aligned flags** — all tools search the *same file universe*: whole tree incl. `.git`/hidden,
  skip binary files, literal/fixed-string, case-insensitive. asmgrep `-ri`, GNU grep `-rIiF`,
  ripgrep `-uuiF --no-heading -N --color never`. Per-language impls take `-r -i`.
- **Correctness gate** — a result only counts if its **match-line count equals GNU grep's**
  (byte-for-byte where checked). A faster-but-wrong impl is a failure, not a win. `compare.sh`
  flags and diffs any `impl ≠ grep`.
- **Byte-level baseline (`LC_ALL=C`)** — the harnesses export `LC_ALL=C` so grep/ripgrep match
  at the **byte** level, exactly like the impls (which read raw bytes = literal `grep -F`
  semantics). This matters: in a UTF-8 locale, GNU grep's `-i` silently *skips* matches on lines
  containing invalid-UTF-8 bytes — e.g. on `jdk`, `LANG=en_US.UTF-8` grep finds 120 754 "error"
  lines but `LC_ALL=C` grep (and every impl) finds 120 766, the 12 extra all in Chinese `.po`
  files with `�` bytes. Without `LC_ALL=C` those 12 lines would spuriously fail the correctness
  gate even though the impls are byte-correct. (`LC_ALL=C` grep is also marginally faster and
  more deterministic, applied uniformly to the baseline.)
- **Warm cache** — `hyperfine --warmup 2` runs the command a few times first, so the page
  cache is hot and we measure **CPU + syscalls, not disk**. (Cold-cache mostly benchmarks the
  SSD, not the code; we deliberately don't report it.) `-N` disables the intermediate shell.
- **Multiple runs** — `hyperfine -M 12` (min 12 runs), reporting the mean; cross-impl ratios use
  geometric means across repos so no single repo dominates.
- **×grep** — `mean(impl) / mean(GNU grep)`, *same run, same corpus, same machine state.*
  `< 1` means faster than grep. **Only compare ×grep within one corpus+session table** — the
  multiplier shifts with the corpus (e.g. CPython is ~4.5× on a tiny synthetic tree but ~10×
  on this repo corpus), which is exactly why the corpus must be pinned.

## Machine state (for low variance / repeatability)

The numbers were taken on an idle machine. For tight, comparable runs:

```sh
# pin CPU to a fixed clock (kills turbo/thermal variance — the #1 source of noise)
sudo cpupower frequency-set -g performance
# (optional) disable turbo so the clock is flat:
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
# run nothing else; close browsers/IDEs. hyperfine already warms the cache.
```

Report `hyperfine`'s mean ± σ; if σ is more than a few % of the mean, the box wasn't quiet —
re-run. Cross-machine numbers are *not* comparable (different cores/IPC/SSD); the **ordering by
runtime model is**, which is the whole point of this project.

## Two harnesses

- **`tests/compare.sh [PATTERN] [repo...]`** — the 3-way asmgrep vs GNU grep vs ripgrep table
  across the pinned corpus (geomean speedup at the bottom). Fast.
- **`tests/leaderboard.sh [PATTERN] [repo...]`** — every language implementation (best shipped
  variant) vs GNU grep → the ×grep leaderboard. Gated on correctness; per-(impl,repo) timeout so
  the slow interpreters don't run for hours on `jdk`.

### The slow-interpreter caveat (an honest limitation)

A byte-at-a-time interpreter (Forth, and to a lesser degree bash/awk/Red/Raku) scanning `jdk`
(809 MB, 70 k files) can take **many minutes per run** — infeasible to benchmark on the huge
end. `leaderboard.sh` applies a per-command timeout (default 60 s): repos that exceed it are
**excluded from that impl's geomean and explicitly marked**, never silently dropped. So the slow
rows are reported on the small/medium corpus only, with a note — the huge-repo column is for the
native/JIT tier that can actually finish it. Silent truncation would read as "covered everything"
when it didn't; the timeout note is the fix.
