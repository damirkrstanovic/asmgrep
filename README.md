# asmgrep

A small but genuinely fast **grep replacement** — literal (fixed-string)
substring search with recursion and case-insensitivity — originally written in
**x86-64 Linux assembly** with **no libc** (just raw syscalls). On real
repositories it runs **~3× faster than GNU grep and ~2× faster than ripgrep**
(geomean, aligned flags), with byte-for-byte identical results.

This repo is also an **experiment**: the same program is reimplemented in **C**,
**Zig**, **Go**, **Rust**, **Odin**, **Java**, **Kotlin**, **Clojure**,
**Common Lisp**, **Haskell**, **OCaml**, **FreePascal**, **Ada**, and **Fortran** —
both *hand-optimized* (same syscall strategy, SIMD, parallel walker)
and *idiomatic stdlib*. The question: *did writing it in assembly buy any of the speed,
or was it the engineering all along?* **Answer below; the short version is: within the
compiled tier it's the engineering, not the language — but for managed JVM runtimes the
startup/warmup tax on a short-lived process becomes the whole story.**

```
grep [-r] [-i] PATTERN PATH...
  -r   recurse into directories
  -i   case-insensitive (ASCII)
  --   end of options
```

Literal substring only — **no regex** (compare against `grep -F` / `rg -F`).
Exit status: `0` = match, `1` = no match, `2` = error.

## Findings

All implementations are **byte-for-byte identical to grep** on every repo tested.
Geomean slowdown vs the hand-written assembly, `-ri error`, 10 repos, 6 cores
(full numbers + methodology in **[docs/RESULTS.md](docs/RESULTS.md)**):

| implementation | vs asm |
|---|--:|
| **optimized** asm / C / Zig (same algorithm + syscall strategy) | 1.0× / ~1.0× / ~1.05× |
| ripgrep | 2.8× |
| GNU grep | 4.6× |
| **idiomatic** single-threaded (C / Zig / Go) | ~14× |
| **idiomatic** + naive threads (C / Zig / Go / Rust) | ~9.7× |
| **idiomatic** + threads + reused buffer + prefix binary-check | **C 3.2× / Zig 2.8× / Go 4.4× / Rust 2.4×** |

Ten more languages were added later (consistent single-pass benchmark, see RESULTS.md) — and
they sort by **runtime model**, not syntax:

| implementation | character |
|---|---|
| **Odin** (compiled, native) | lands in the C/Zig idiomatic cluster (~3.5× single-threaded); sub-ms startup |
| **Common Lisp** (SBCL native image) | ~3.4 ms startup, tuned-MT scan on par with GNU grep — a dynamic language that performs like a systems one |
| **Haskell** (GHC, native + RTS) | ~17 ms startup; immutable `ByteString` *forbids* the buffer-reuse pillar, so it's pinned in the allocation-heavy regime (~1.5× threading) |
| **OCaml** (ocamlopt+flambda, Domains) | 1.0 ms startup; mutable `Bytes` ⇒ buffer reuse works, tuned-MT scales ~3.8×; slow single-threaded scan (hand-rolled search, no stdlib `memmem`) — flambda+`-O3` bought only ~9%, so it's the algorithm, not the compiler |
| **FreePascal** (fpc, native) | **0.41 ms** startup (fastest after asm); buffer reuse works; hand-rolled-search algorithm tax single-threaded |
| **Ada** (GNAT, tasks) | 0.60 ms startup; per-task buffer reuse scales ~3.5×; hand-rolled scalar search ⇒ slow single-threaded |
| **Fortran** (gfortran, OpenMP) | 0.80 ms startup; built-in `index()` substring search ⇒ ~2× faster single-threaded than Ada, and tuned-MT *ties GNU grep*; walk needs `iso_c_binding` opendir/readdir |
| **Java / Kotlin** (JVM, bare `java`) | ~30–41 ms fixed startup; on short jobs the JIT never warms and threads make it *worse* (tuned-MT slower than single-threaded) |
| **Clojure** (JVM, AOT) | ~0.45 s runtime-init constant before any work — in a class of its own |

### 1. The language barely matters *(within the compiled tier)*

Within a tier, every language clusters: optimized asm ≈ C ≈ Zig; idiomatic
C ≈ Zig ≈ Go ≈ Rust (≤ ~1.8× apart). The gap *between* tiers is ~14×. Hand-written
assembly bought **~nothing** on the actual work — a modern compiler matches it and
the out-of-order CPU does the register allocation/scheduling anyway. Assembly's only
real edge is no-libc startup on sub-2 ms inputs. Odin (native) joins this cluster; even
SBCL's native image is close. The clustering **breaks for JVM runtimes** — there the
startup + JIT-warmup tax on a short-lived process, not the language or algorithm,
sets the floor (Java/Kotlin ~30–40 ms, Clojure ~0.45 s). See RESULTS.md.

### 2. Performance is three pillars — and they *interact*

1. **Parallelism** (~6× on 6 cores) — *but only if pillar 2 lets it scale.*
2. **Memory / I-O strategy** — two rules: **(a)** reuse one buffer per thread (don't
   allocate per file), and **(b)** don't read data you'll skip (check binary on a
   64 KB *prefix* before reading the rest). Per-file allocation / reading huge files
   in full causes ~100× more page faults (80k vs ~800 on immich), and faulting fresh
   pages under N threads serializes on the kernel page-table lock.
3. **Algorithm** — least important here: stdlib `memmem`/`bytes.Index`/`memchr` are
   already fast SIMD; the hand-rolled two-byte filter barely helped.

The killer demonstration: bolting threads onto idiomatic code recovered only **1.45×**
(not 6×) — page-fault contention capped it. Fixing *only* the memory strategy (two
~3-line changes, no algorithm/language change) took it from 9.7× to ~2.4–4.4×, **past
grep and approaching ripgrep**. You cannot bolt parallelism onto allocation-heavy code
and expect it to scale.

### 3. Things measured and *not* shipped

- **io_uring** batched reads: only 1.1–1.3× on warm-cache files → not worth it (see `bench/`).
- **Boyer-Moore-Horspool**: 4× *slower* than the SIMD scan for short patterns (latency-bound
  scalar loop) → gated to ≥32-char patterns only.

## Layout

```
asm/grep.s        assembly implementation        (optimized)
c/grep.c          C, hand-optimized              (same logic as asm)
zig/grep.zig      Zig, hand-optimized            (same logic as asm)
c/grep_std.c      C, idiomatic stdlib            (nftw + memmem, single-threaded)
zig/grep_std.zig  Zig, idiomatic stdlib          (std.Io.Dir + findPos)
go/grep.go        Go, idiomatic stdlib           (filepath.WalkDir + bytes.Index)
c/grep_std_mt.c   C, idiomatic + pthreads        (multithreaded)
zig/grep_std_mt.zig  Zig, idiomatic + std.Thread (multithreaded)
go/mt/main.go     Go, idiomatic + goroutines     (multithreaded)
rust/             Rust, idiomatic walkdir+rayon+memchr (parallel; ripgrep's crates)
odin/             Odin, 3 variants (native compiled, like C/Zig)
java/             Java (JDK), 3 variants (idiomatic / +threads / +tuned)
kotlin/           Kotlin (JVM), 3 variants
clojure/          Clojure (JVM, AOT'd uberjars via Leiningen), 3 variants
lisp/             Common Lisp (SBCL save-lisp-and-die native images), 3 variants
haskell/          Haskell (GHC, native + threaded RTS), 3 variants
ocaml/            OCaml (ocamlopt native, OCaml-5 Domains), 3 variants
pascal/           Free Pascal (fpc native), 3 variants
ada/              Ada (GNAT native, tasks + protected objects), 3 variants
fortran/          Fortran (gfortran native, OpenMP; C-interop walk), 3 variants
bench/            iouring_probe.c and friends
docs/RESULTS.md   full benchmark numbers + methodology
tests/            run.sh (correctness vs grep), verify_impl.sh (any binary vs grep),
                  compare.sh / bench.sh (perf, hyperfine)
bin/              build output (git-ignored): native binaries + JVM launcher scripts
```

`make all` builds asm + C; `make c`/`make zig`/`make cstd`/`make zigstd`/`make go`/
`make odin`/`make lisp` build the native rest; `make java`/`make kotlin`/`make clojure`
(or `make jvm` for all three) build the JVM versions. The JVM and Lisp builds drop
launcher scripts / native executables into `bin/` named `jgrep_std*`, `ktgrep_std*`,
`cljgrep_std*`, `clgrep_std*`, `odingrep_std*` (suffixes: `_mt` naive threads,
`_mt_tuned` reused-buffer + prefix-check).

## Build & run

```sh
make             # builds the assembly version -> bin/asmgrep
make c           # builds the C version        -> bin/cgrep   (gcc/clang)
make zig         # builds the Zig version      -> bin/zgrep   (needs `zig`)
make all         # asm + C

make odin        # Odin native      (needs `odin`)
make lisp        # Common Lisp      (needs `sbcl`; native saved images)
make haskell     # Haskell          (needs `ghc`; native + threaded RTS)
make ocaml       # OCaml            (needs `ocamlopt`; OCaml-5 Domains)
make pascal      # Free Pascal      (needs `fpc`)
make ada         # Ada             (needs `gnatmake`)
make fortran     # Fortran         (needs `gfortran`; OpenMP for MT)
make java        # Java             (needs JDK `javac`/`java`)
make kotlin      # Kotlin           (needs `kotlinc`)
make clojure     # Clojure          (needs `lein`; AOT'd uberjars)
make jvm         # java + kotlin + clojure

bin/asmgrep -ri ontology /path/to/repo

make test        # correctness: 14 cases + a parallel-path case vs grep -F
./tests/verify_impl.sh bin/jgrep_std bin/odingrep_std ...  # check any binary vs grep
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
