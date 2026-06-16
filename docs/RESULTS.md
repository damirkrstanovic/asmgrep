# asmgrep — benchmark results & findings

A literal-substring grep written in x86-64 assembly (no libc), compared against
GNU grep and ripgrep across real repositories in `/home/damirk/src`.

Reproduce: `make test` (correctness), `make bench` (synthetic), `tests/compare.sh` (cross-repo).
All tools invoked by absolute path to bypass the shell's `grep` wrapper.

## Optimizations implemented

| technique | effect |
|---|---|
| binary-file skip (NUL peek) | skips git packs / blobs like grep `-I` and ripgrep |
| buffered output (~64KB) | one `write()` instead of ~4 syscalls per matching line |
| mmap + search-then-locate-line | only find line bounds *around* a candidate hit |
| SSE2 + AVX2 scan (CPUID-gated) | 16/32 bytes per iteration |
| rare-byte heuristic | memchr the least-frequent pattern byte |
| two-byte filter | require two pattern bytes at a fixed distance (kills `-i` candidate storms) |
| adaptive strategy | single-byte memchr when rare byte is rare, two-byte when common |
| Boyer-Moore-Horspool | built + correct, but **only for patterns ≥32 chars** — see note |
| **multithreading** | `clone` thread-pool; one core per worker |
| **parallel walker** | shared directory work-queue; walk + search both parallel |
| **read() small files** | one `read()` into a reused buffer, not `mmap`/`munmap`/`fstat` |

**read() vs mmap:** profiling showed asmgrep was syscall-bound on repos —
`open`+`munmap`+`close`+`mmap`+`fstat` were ~93% of execution, and `mmap`+`munmap`
alone 37% *plus* hidden minor-page-faults on every touched page. Switching files
≤256 KB to a single `read()` into a per-thread buffer (mmap kept only for larger
files) cut per-file syscalls 5→3 and removed the faults: on immich, `fstat`
3799→62, `mmap` 3791→67, `munmap` 3786→62, and **system time dropped 2.3×**. This
was a **2.02× speedup over the mmap build** and is what pushed asmgrep well past
ripgrep.

**Threading model:** workers pull **directories** off a shared spinlock-guarded
queue (test-and-test-and-set to avoid lock-line bouncing), `getdents64` each one,
and use `d_type` to dispatch — subdirs are pushed back on the queue, files are
searched inline. So walking and searching run concurrently across all cores, and
`d_type` removes the old per-entry `newfstatat` (≈4400 stats gone on a mid-size
repo). Termination is an atomic `pending` counter (dirs discovered but not yet
processed); a worker exits only when the queue is empty *and* `pending == 0`.
Each worker owns a **private 64 KB context** (output buffer + `statbuf`) and
flushes under one output spinlock; each line is emitted atomically so a flush
never splits a line. The main thread walks alone until enough subdirectories
accumulate, then spawns helpers (`clone`, joined via `CLONE_CHILD_CLEARTID` +
`futex`) — so tiny trees never pay spawn cost. Cross-file output order is
unspecified when parallel, exactly like ripgrep.

This was the change that put asmgrep *ahead* of ripgrep on average: the walk had
been single-threaded, and on a miss vs a hit immich took identical time (27 ms) —
proving the bottleneck was walk + per-file syscalls, not matching. Our kernel
time was 66 ms vs ripgrep's 28 ms; parallelizing the walk and dropping the double
-stat closed most of it.

**BMH note:** measured *4× slower* than the SIMD scan for normal (short) patterns —
its scalar skip loop is latency-bound (each step's load address depends on the
previous byte, no ILP), which loses to vectorized full-scan on this CPU. It is
retained only for long patterns where the skip distance finally outweighs that.

## Correctness

`tests/run.sh`: 13/13 unit cases match `grep -F`. Fuzzing 60+ patterns (incl.
regex metachars, `-i`, BMH-length) over a real corpus: 0 mismatches.
**Cross-repo: all 17 repos, asmgrep == grep == ripgrep match counts, exactly.**

## Performance — ALIGNED flags (fair: same file universe, all skip binary)

`asmgrep -ri` vs `grep -rIiF` vs `rg -uuiF`, pattern `error`, 6-core machine.
Multithreaded asmgrep (single-threaded numbers in parentheses for reference):

| repo | size | asm ms | grep ms | rg ms | vs grep | vs rg |
|---|--:|--:|--:|--:|--:|--:|
| archy | 668K | 1.04 | 1.59 | 3.45 | 1.53× | 3.32× |
| linuxutil | 6.2M | 1.15 | 1.76 | 4.77 | 1.53× | 4.15× |
| gst-rtsp-server | 5.8M | 1.43 | 2.79 | 3.97 | 1.95× | 2.78× |
| potemkin | 13M | 2.59 | 4.76 | 4.42 | 1.84× | 1.71× |
| gdd | 20M | 15.5 | 17.0 | 6.88 | 1.10× | 0.45× |
| snapcast | 29M | 2.47 | 4.02 | 4.11 | 1.63× | 1.66× |
| navidrome | 29M | 12.0 | 15.5 | 7.97 | 1.29× | 0.67× |
| omarchy | 66M | 5.11 | 6.14 | 4.74 | 1.20× | 0.93× |
| anchor-core | 81M | 8.11 | 9.99 | 8.29 | 1.23× | 1.02× |
| camilladsp | 86M | 1.61 | 2.78 | 3.69 | 1.73× | 2.29× |
| trustgraph | 101M | 6.62 | 12.3 | 6.09 | 1.86× | 0.92× |
| jellyfin | 101M | 17.2 | 27.6 | 7.95 | 1.61× | 0.46× |
| gaia | 102M | 9.06 | 13.2 | 6.36 | 1.45× | 0.70× |
| graph-finder | 120M | 27.2 | 22.3 | 8.20 | 0.82× | 0.30× |
| cognee | 173M | 12.8 | 24.4 | 7.88 | 1.91× | 0.62× |
| onyx | 194M | 18.7 | 27.6 | 10.1 | 1.47× | 0.54× |
| immich | 420M | 26.7 | 48.2 | 12.2 | 1.80× | 0.46× |

**Geomean (current, read() build): asmgrep vs grep = 3.13×, asmgrep vs ripgrep = 2.14×.**
Progression: single-threaded 0.96× / 0.68× → thread-pool over file list
1.49× / 1.00× → parallel directory walker 1.59× / 1.07× → **read() small files
3.13× / 2.14×**. (The per-repo table above is the parallel-walker/mmap build kept
as the reference "gold" baseline; the read() build is ~2× faster than it across
the board — e.g. immich 16.7→8.2 ms, jellyfin 9.8→3.4 ms, graph-finder 18→4.1 ms.)

Per-repo highlights (asm ms / grep ms / rg ms): cognee 8.99 / 24.3 / 8.33
(2.70× grep), immich 18.8 / 47.7 / 13.1 (2.54× grep, 0.70× rg), jellyfin
12.3 / 27.4 / 8.24 (2.23× grep). Remaining rg wins are the largest trees
(immich, jellyfin, onyx) and the scan-bound `graph-finder`.

## Performance — DEFAULT usage (as actually typed)

`grep -r` scans binary by default; `asmgrep -r` and `rg` skip it; `rg` also
obeys `.gitignore` and skips `.git` entirely.

| repo | asmgrep vs `grep -r` | rg vs asmgrep |
|---|--:|--:|
| trustgraph (101M, 91MB pack) | ~6.5× faster | 1.38× |
| navidrome (29M) | ~1.2× faster | 2.11× |
| onyx (194M) | ~2.0× faster | 2.24× |

## Honest conclusions

1. **Correctness is rock-solid** — set-identical to grep and ripgrep on every repo,
   stable across 15–20× repeated runs (no races) including the concurrent walker.
2. **asmgrep beats GNU grep by ~1.6×** geomean, winning 16/17 repos.
3. **asmgrep edges ripgrep (1.07× geomean)** — clearly ahead on small/medium repos,
   roughly even on many large ones; ripgrep still leads on the very largest trees
   (immich 0.70×, jellyfin 0.67×, onyx 0.78×).
4. **Two soft spots:** `graph-finder` (0.45× vs rg) is scan-bound — few matches in
   big data files where glibc's AVX-512 `memchr` out-scans our AVX2; and `archy`
   (a 0.7 MB repo) is borderline vs grep, where thread-spawn cost rivals the whole
   ~1.5 ms job.

## io_uring: measured, then declined (with data)

The remaining kernel cost is per-file `open`/`read`/`close`. io_uring can batch
those so N files cost a few `io_uring_enter` calls instead of 3N syscalls — the
textbook "fewer user↔kernel transitions" tool. Before building it into the
(threaded, hand-asm) walker, a C microbenchmark (`iouring_probe.c`) measured the
ceiling: read every file in a tree via sync `open/read/close` vs io_uring batched
(200-file batches), single-threaded, warm cache:

| repo | sync ms | io_uring ms | speedup |
|---|--:|--:|--:|
| trustgraph | 3.46 | 2.58 | 1.34× |
| navidrome | 6.83 | 5.41 | 1.26× |
| jellyfin | 9.20 | 7.30 | 1.26× |
| onyx | 9.86 | 8.00 | 1.23× |
| immich | 15.2 | 13.5 | 1.13× |

**Verdict: not worth integrating.** Only **1.1–1.3×** on the read portion *in
isolation* — because for cache-resident files the kernel still does every path
lookup and copy; io_uring only removes syscall-*entry* overhead, a small slice of
the per-file cost. Integrated, that gain would shrink much further: reads are only
part of asmgrep's already-parallel work, and the walker discovers files per
directory (small batches, where the benefit is far below the 200-file-batch
number). Against that: per-thread rings, a ~77 MB buffer pool (200×64 KB × 6), and
an async rework. io_uring shines for **cold-cache / high-latency** I/O (its async
hides waiting); interactive grep is warm-cache, so `read()` was the right call.

## What would extend the lead further

- **Faster big-file scan** — AVX-512 `memchr`-class isn't available on this CPU; on
  AVX2 the lever is a leaner single-byte scan + non-temporal loads.
- **gitignore/.git pruning** — would slash work in default usage like ripgrep.
- **io_uring** — only worthwhile for cold-cache / network-FS workloads (see above).
