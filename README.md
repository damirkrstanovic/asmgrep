# asmgrep

A small but genuinely fast **grep replacement written in x86-64 Linux assembly**
(GNU `as`, Intel syntax), with **no libc** — just raw syscalls. It does literal
(fixed-string) substring search with recursion and case-insensitivity, and on
real repositories it runs **~3× faster than GNU grep and ~2× faster than
ripgrep** (geomean, aligned flags), with byte-for-byte identical results.

```
asmgrep [-r] [-i] PATTERN PATH...

  -r   recurse into directories
  -i   case-insensitive (ASCII)
  --   end of options
```

Literal substring match only — **no regular expressions** (compare against
`grep -F` / `rg -F`). Exit status: `0` = match, `1` = no match, `2` = error.

## Build & run

```sh
make            # assembles grep.s -> asmgrep   (as + ld, no compiler/libc)
./asmgrep -ri ontology /path/to/repo

make test       # correctness: 14 cases + a parallel-path case vs grep -F
make bench      # synthetic micro-benchmarks vs grep -F (needs hyperfine)
./tests/compare.sh   # 3-way asmgrep vs grep vs ripgrep across repos
```

Requires an x86-64 Linux box. SSE2 is baseline; AVX2 is detected at runtime via
CPUID and used when present.

## How it gets its speed

Every optimization is justified by measurement — see **[RESULTS.md](RESULTS.md)**
for the full numbers and methodology. In short:

- **Binary-file skip** — peek for a NUL byte and skip the file (like `grep -I`/rg),
  so git packs and blobs aren't scanned.
- **SIMD scanning** — SSE2/AVX2 search for the *rarest* pattern byte, a two-byte
  "memmem" filter to kill case-insensitive candidate storms, an adaptive
  single-vs-two-byte choice, and Boyer-Moore-Horspool for long (≥32-char) patterns.
- **Search-then-locate-line** — find a candidate first, only then compute line
  bounds, so non-matching data is skipped at SIMD speed.
- **Multithreading** — a `clone()` thread pool sized to the CPU affinity mask
  (capped at 16), with a lazy spawn gate so tiny trees stay single-threaded.
- **Parallel directory walker** — workers pull directories off a shared work-queue,
  use `d_type` to dispatch (no per-entry stat), search files inline, and push
  subdirectories back; output is per-line atomic across threads.
- **`read()` small files** — the single biggest win: read files ≤256 KB into a
  reused per-thread buffer instead of `mmap`/`munmap` (which costs a page fault per
  touched page); `mmap` is kept only for larger files.

## Why there are three `.s` source files

There are really **two** distinct builds; one is checkpointed twice. The two
checkpoint copies (`*.gold`, `*.read`) are **git-ignored scratch artifacts** kept
only for A/B benchmarking — `grep.s` is the real, tracked source.

| file | tracked? | what it is |
|---|---|---|
| **`grep.s`** | yes | **The active source.** The current best build — the `read()`-into-buffer version. `make` builds this. |
| `grep.s.gold` | no (ignored) | The **"gold" baseline**: the earlier build that used `mmap`/`munmap` per file. Kept to measure improvements *against* — it's the reference the `read()` change was compared to (and won by ~2×). |
| `grep.s.read` | no (ignored) | A checkpoint taken when the `read()` optimization was finished, **identical to `grep.s` today**. It exists so the `read()` build could be saved before the io_uring experiment, and so both builds (`asmgrep.gold` vs `asmgrep.read`) can be benchmarked side by side. |

So: `grep.s` == `grep.s.read` (current), and `grep.s.gold` is the previous
`mmap`-based version. The matching binaries `asmgrep.gold` / `asmgrep.read` are
also git-ignored. If you only care about the project, `grep.s` is all you need —
the other two are a frozen "before/after" pair for reproducing the headline
`read()`-vs-`mmap` result.

## Also in here

- **`iouring_probe.c`** — a C microbenchmark that measured io_uring batched reads
  at only **1.1–1.3×** over plain `read()` on warm-cache files. That's why io_uring
  was *measured but deliberately not integrated* (it pays off for cold-cache /
  high-latency I/O, not warm-cache grep). See RESULTS.md for the reasoning.

## Caveats

- Literal patterns only (no regex), ASCII case folding only.
- Parallel output is per-line correct but **not ordered across files** (like
  ripgrep's default); single-threaded small jobs stay in directory order.
- Symlinks are not followed during recursion (matches `grep -r`'s default).
