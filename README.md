# asmgrep

A small but genuinely fast **grep replacement** — literal (fixed-string)
substring search with recursion and case-insensitivity — originally written in
**x86-64 Linux assembly** with **no libc** (just raw syscalls). On real
repositories it runs **~3× faster than GNU grep and ~2× faster than ripgrep**
(geomean, aligned flags), with byte-for-byte identical results.

This repo is also an **experiment**: the same program is reimplemented in **C**
(`c/grep.c`) and **Zig** (`zig/grep.zig`) with the *same logic* — same syscall
strategy, same SIMD two-byte filter, same parallel walker, same `read()`-into-buffer.
The question: *did writing it in assembly actually buy any of the speed?*

**Answer: essentially no.** With the same algorithm, C and Zig land within ~1.01–1.05×
of the hand-written assembly on real (work-dominated) repos — sometimes faster. The
speed was always the algorithm + syscall strategy, not the language. Assembly's only
measurable edge is **process startup on tiny inputs** (no libc to initialize), a
fixed fraction of a millisecond that vanishes once the job is real. Full numbers
and the (instructive) wrong turns are in **[docs/RESULTS.md](docs/RESULTS.md)**.

```
grep [-r] [-i] PATTERN PATH...
  -r   recurse into directories
  -i   case-insensitive (ASCII)
  --   end of options
```

Literal substring only — **no regex** (compare against `grep -F` / `rg -F`).
Exit status: `0` = match, `1` = no match, `2` = error.

## Layout

```
asm/grep.s        the assembly implementation (the original)
c/grep.c          the C implementation        (same logic)
zig/grep.zig      the Zig implementation       (same logic)
bench/            iouring_probe.c and friends
docs/RESULTS.md   full benchmark numbers + methodology
tests/            run.sh (correctness), compare.sh / bench.sh (perf, hyperfine)
bin/              build output (git-ignored)
```

## Build & run

```sh
make             # builds the assembly version -> bin/asmgrep
make c           # builds the C version        -> bin/cgrep   (gcc/clang)
make zig         # builds the Zig version      -> bin/zgrep   (needs `zig`)
make all         # asm + C

bin/asmgrep -ri ontology /path/to/repo

make test        # correctness: 14 cases + a parallel-path case vs grep -F
make bench       # synthetic micro-benchmarks (needs hyperfine)
./tests/compare.sh   # asmgrep vs grep vs ripgrep across repos
```

x86-64 Linux. SSE2 is baseline; AVX2 is detected at runtime via CPUID.

## How it gets its speed

Every optimization is justified by measurement — see **[docs/RESULTS.md](docs/RESULTS.md)**.
In short:

- **Binary-file skip** — peek for a NUL byte and skip the file (like `grep -I`/rg).
- **SIMD scanning** — search for the *rarest* pattern byte, a two-byte "memmem"
  filter to kill case-insensitive candidate storms, an adaptive single-vs-two-byte
  choice, and Boyer-Moore-Horspool for long (≥32-char) patterns.
- **Search-then-locate-line** — find a candidate first, only then compute line
  bounds, so non-matching data is skipped at SIMD speed.
- **Multithreading** — a thread pool sized to the CPU affinity mask (capped at 16),
  with a lazy spawn gate so tiny trees stay single-threaded.
- **Parallel directory walker** — workers pull directories off a shared work-queue,
  use `d_type` to dispatch (no per-entry stat), search files inline, push subdirs
  back; output is per-line atomic across threads.
- **`read()` small files** — the single biggest win: read files ≤256 KB into a
  reused per-thread buffer instead of `mmap`/`munmap` (which costs a page fault per
  touched page); `mmap` is kept only for larger files.

## The `asm/` checkpoints (`*.gold`, `*.read`)

`asm/grep.s` is the real, tracked source. Two **git-ignored** scratch copies sit
beside it for A/B benchmarking:

| file | what it is |
|---|---|
| `asm/grep.s` | the active source — the `read()`-into-buffer build (`make` builds this) |
| `asm/grep.s.gold` | the earlier `mmap`/`munmap`-per-file build, kept as the baseline the `read()` change was measured against (it won ~2×) |
| `asm/grep.s.read` | a checkpoint of the `read()` build, **identical to `asm/grep.s`** — frozen before the io_uring experiment so both builds could be benchmarked side by side |

If you only care about the project, `asm/grep.s` is all you need.

## Also in here

- **`bench/iouring_probe.c`** — a microbenchmark that measured io_uring batched
  reads at only **1.1–1.3×** over plain `read()` on warm-cache files, which is why
  io_uring was *measured but deliberately not integrated* (it pays off for
  cold-cache / high-latency I/O, not warm-cache grep).

## Caveats

- Literal patterns only (no regex), ASCII case folding only.
- Parallel output is per-line correct but **not ordered across files** (like
  ripgrep's default); single-threaded small jobs stay in directory order.
- Symlinks are not followed during recursion (matches `grep -r`'s default).
