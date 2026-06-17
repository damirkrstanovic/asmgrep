# asmgrep — benchmark results & findings

A literal-substring grep written in x86-64 assembly (no libc), compared against
GNU grep and ripgrep across real repositories in `/home/damirk/src`.

Reproduce: `make test` (correctness), `make bench` (synthetic), `tests/compare.sh` (cross-repo).
All tools invoked by absolute path to bypass the shell's `grep` wrapper.

## Two tiers: optimized vs idiomatic (and why language barely matters)

Follow-up experiment. We'd argued the speed came from two things: the **algorithm**
and the **syscall strategy**. To separate "the language" from "the engineering",
each language got two implementations:

- **optimized** (`asm/grep.s`, `c/grep.c`, `zig/grep.zig`): same hand-tuned design —
  raw syscalls, `read()` into a reused buffer, SIMD two-byte filter, parallel walker.
- **idiomatic** (`c/grep_std.c`, `zig/grep_std.zig`, `go/grep.go`): how you'd *normally*
  write it — high-level stdlib walking (`nftw` / `std.Io.Dir.walk` / `filepath.WalkDir`),
  whole-file reads (`fread` / `readFileAlloc` / `os.ReadFile`), stdlib substring search
  (`memmem` / `std.mem.findPos` / `bytes.Index`). Single-threaded.

All eight are byte-for-byte identical to grep. `-ri error`, mean ms, 6 cores:

| repo | asm | C·opt | Zig·opt | C·std | Zig·std | Go | grep | rg |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| navidrome | 2.72 | 3.04 | 3.38 | 30.5 | 32.7 | 46.1 | 15.0 | 7.33 |
| trustgraph | 1.91 | 2.14 | 2.43 | 53.9 | 48.9 | 58.5 | 12.2 | 5.87 |
| cognee | 4.07 | 4.01 | 4.01 | 88.9 | 89.0 | 112 | 23.5 | 7.96 |
| onyx | 4.61 | 4.98 | 5.06 | 110 | 105 | 140 | 26.6 | 9.68 |
| immich | 8.65 | 7.85 | 8.76 | 196 | 216 | 275 | 46.7 | 12.3 |

**Geomean slowdown vs optimized asm:** idiomatic C **14.5×**, Zig **14.3×**, Go **19.0×**;
GNU grep 4.6×, ripgrep 2.8×. **Idiomatic languages vs each other: C=1.00, Zig=0.98,
Go=1.30** — essentially the same.

The takeaways:
1. **Within each tier, the language is irrelevant.** Optimized asm ≈ C ≈ Zig; idiomatic
   C ≈ Zig ≈ Go. The spread *between* languages (≤1.3×) is dwarfed by the spread between
   *tiers* (~14×).
2. **The ~14× gap is the engineering, not the language** — and it's mostly the two
   levers we identified: **parallelism (~6× on 6 cores)** and **I/O strategy** (reused
   buffer + raw `read()` vs per-file allocation + whole-file stdlib reads, ~2.4×).
3. The custom **matching algorithm barely mattered**: stdlib `memmem`/`findPos`/`bytes.Index`
   are already fast SIMD scans. Our hand-rolled two-byte SIMD filter was *not* the win —
   threading and I/O were. (The earlier 2–66× "naive C" disaster was a self-inflicted
   algorithm bug, not a property of stdlib search.)
4. "Just use the stdlib" leaves you **~14–19× slower than careful code and 3–4× slower
   than the grep/ripgrep you were trying to beat** — even in C or Zig. Go trails the
   others ~1.3× (GC + per-file `os.ReadFile` allocation).

### Adding threads to the idiomatic versions (and why it barely helps)

So we parallelized the idiomatic versions with each language's natural concurrency
(C pthreads, Zig `std.Thread`, Go goroutines) and added **Rust** in its canonical
idiomatic form — `walkdir` + `rayon` + `memchr` (the crates ripgrep is built from),
parallel by default. All byte-identical to grep. `-ri error`, mean ms:

| repo | asm | C·mt | Zig·mt | Go·mt | Rust | grep | rg |
|---|--:|--:|--:|--:|--:|--:|--:|
| navidrome | 2.72 | 11.0 | 11.1 | 14.8 | 10.7 | 15.0 | 7.88 |
| trustgraph | 1.98 | 43.6 | 38.8 | 39.1 | 43.4 | 12.0 | 5.45 |
| cognee | 3.81 | 67.0 | 61.3 | 61.0 | 68.1 | 23.4 | 8.14 |
| onyx | 4.63 | 77.4 | 67.2 | 73.5 | 73.8 | 26.6 | 9.79 |
| immich | 8.56 | 150 | 135 | 139 | 153 | 46.9 | 13.4 |

**Geomean vs optimized asm: C·mt 9.7×, Zig·mt 9.4×, Go·mt 9.8×, Rust 9.8×.** Adding
6 cores only moved idiomatic from ~14× to ~9.7× — a **1.45×** gain, not the ~6× you'd
expect. They don't scale, and they're *still slower than single-threaded grep*.

**Why: per-file allocation caps parallelism.** Diagnosed on immich (20 runs, no strace):

| | minor page faults / run | parallelism (CPU-time / wall) |
|---|--:|--:|
| idiomatic-MT (per-file alloc) | **83,111** | ~1.7× |
| optimized (reused buffer) | **786** | ~4.7× |

Reading each file into a *fresh* buffer means every buffer's pages must be faulted in
(zero-page → anonymous page) as they're written — **~100× more minor page faults**. Under
N threads, the kernel page-fault path contends on the mm/page-table lock (and `munmap`
adds TLB-shootdown IPIs), so the work **serializes in the kernel** (system time 4.2 s vs
0.58 s). The optimized versions allocate one buffer **per thread and reuse it**, so pages
stay resident (~786 faults) and the work actually scales.

**The deepest lesson of the whole experiment:** the pillars *interact*. Parallelism
(pillar 1) only pays off if the memory strategy (pillar 2) avoids per-file allocation —
otherwise page-fault contention caps you at ~1.5×. You cannot bolt threads onto
allocation-heavy code and expect linear speedup. And again, **language is irrelevant**:
idiomatic C ≈ Zig ≈ Go ≈ Rust, all ~9.7×, because they all allocate per file.

### Fixing the memory strategy (and watch them finally scale)

So we changed *only* the memory strategy in the threaded idiomatic versions, keeping
every other idiom (stdlib walk, stdlib search, native threads): **(a) reuse one buffer
per thread** instead of allocating per file, and **(b) check binary on a 64 KB prefix
before reading the rest**. Why (b)? Reuse alone barely moved the needle — investigation
showed the residual cost was reading immich's **291 MB `.git` pack fully into the buffer
before the binary check** (the idiomatic "read whole file then search" pattern). That one
read faults ~71k pages; buffer reuse can't help a single 291 MB read. The optimized
version never hits this because it `mmap`s large files lazily and only touches the
binary-check prefix.

| | minor page faults / run (immich) | geomean vs asm |
|---|--:|--:|
| naive MT (per-file alloc, full read) | ~80,000 | ~9.7× |
| **+ buffer reuse + prefix binary-check** | **~2,000–4,000** | **C 3.2× / Zig 2.8× / Go 4.4× / Rust 2.4×** |

`-ri error`, mean ms (reuse + prefix build):

| repo | asm | C·mt | Zig·mt | Go·mt | Rust | grep | rg |
|---|--:|--:|--:|--:|--:|--:|--:|
| trustgraph | 2.07 | 6.27 | 5.38 | 9.11 | 5.28 | 12.0 | 5.88 |
| cognee | 4.23 | 15.1 | 14.0 | 26.8 | 13.0 | 23.8 | 8.02 |
| jellyfin | 3.65 | 13.5 | 11.0 | 16.6 | 9.12 | 26.8 | 7.71 |
| immich | 8.99 | 23.2 | 23.4 | 31.7 | 14.8 | 46.9 | 12.5 |

With the memory strategy fixed, the threaded idiomatic versions drop from ~9.7× to
~2.4–4.4× of the hand-written asm — **now faster than GNU grep (5.7×) and approaching
ripgrep (2.1×)**, with Rust closest. Two ~3-line changes (reuse + prefix check), no
algorithm or language change, recovered nearly all of the parallelism the naive
threading couldn't reach. That is the memory-strategy pillar, isolated.

(Language still barely matters: the C/Zig/Go/Rust spread is ~1.8×; Rust leads, Go trails
on GC + goroutine overhead.)

## Does the assembly matter? (C and Zig reimplementations)

The headline question: did *writing it in assembly* buy the speed, or was it the
algorithm + syscall strategy all along? To find out, the exact same program was
reimplemented in **C** (`c/grep.c`, gcc `-O2 -march=native`, AVX2 intrinsics,
pthreads) and **Zig** (`zig/grep.zig`, `-O ReleaseFast`, `@Vector(32,u8)`,
`std.Thread`, raw `std.os.linux` syscalls) — same algorithm, same SIMD two-byte
filter, same `read()`-into-buffer, same parallel walker. All three are byte-for-byte
identical to `grep` on every repo.

`-ri error`, mean ms, 6 cores:

| repo | asm | C | Zig | grep | rg |
|---|--:|--:|--:|--:|--:|
| archy | 0.61 | 1.13 | 1.49 | 1.64 | 3.82 |
| linuxutil | 1.00 | 1.62 | 1.66 | 1.96 | 3.81 |
| navidrome | 3.91 | 3.97 | 4.42 | 17.1 | 8.71 |
| trustgraph | 2.60 | 2.80 | 2.84 | 13.6 | 6.75 |
| cognee | 5.88 | 5.14 | 6.29 | 27.1 | 8.88 |
| onyx | 6.90 | 6.20 | 6.40 | 29.5 | 11.9 |
| jellyfin | 5.34 | 5.90 | 5.32 | 30.8 | 8.66 |
| immich | 12.2 | 11.5 | 11.7 | 54.3 | 14.2 |

**Geomean vs asm: C = 1.14×, Zig = 1.23× over 10 repos — but on the big
(work-dominated) repos, C = 1.01× and Zig = 1.05×, i.e. identical.** On several
large repos C and Zig are *faster* than the hand asm (cognee, onyx, immich).

**Conclusion: the assembly bought essentially nothing for the actual grep work.**
The speed came from the algorithm and syscall strategy, which are
language-independent; a modern optimizing compiler (gcc/zig) produces machine code
as good as hand asm for these hot loops, and the CPU does the register
allocation/scheduling dynamically anyway. The *only* place asm wins is **process
startup on tiny inputs** (archy/linuxutil, sub-2 ms): with no libc/runtime to
initialize and a lazy thread-spawn gate, asm starts in ~0 while C/Zig pay
libc + pthread setup — a fixed ~0.3–0.5 ms that's invisible once the job is real.

A cautionary data point from the build process: a *naive* C version (using
`memchr` per pivot occurrence instead of the continuous SIMD two-byte scan) was
**2–66× slower** on `r`-dense files (cognee, gaia). That gap was the *algorithm*,
not the language — which is the whole point.

## Ten more languages: managed runtimes + seven more compiled (2026-06-17)

Extending the thesis past the systems-language cluster. Ten additions, each in the
same three tiers (idiomatic single-threaded / +naive threads / +reused-buffer+prefix-check):

- **Odin** (`odin/`, native, LLVM backend), **OCaml** (`ocaml/`, `ocamlopt` native, OCaml-5
  Domains), **FreePascal** (`pascal/`, `fpc` native), **Haskell** (`haskell/`, GHC native +
  threaded RTS), **Ada** (`ada/`, GNAT native, tasks + protected objects), **Fortran**
  (`fortran/`, gfortran native, OpenMP; recursive walk via `iso_c_binding` opendir/readdir/lstat)
  — *compiled* languages, expected to land near C/Zig.
- **Java** (`java/`, JDK 26, plain `.class`), **Kotlin** (`kotlin/`, fat jar), **Clojure**
  (`clojure/`, AOT'd uberjar) — JVM **managed runtimes**: startup + JIT warmup on a
  short-lived process is a new axis the C/Zig/Go/Rust lineup couldn't show.
- **Common Lisp** (`lisp/`, SBCL `save-lisp-and-die` → native image) — a dynamic language
  that nonetheless compiles to native code and ships as a standalone executable.

All 30 are byte-for-byte identical to `grep` (`tests/verify_impl.sh`, 16 cases each = 480/480).
*Methodology note:* the three tables below were **re-measured in one consistent pass on an
idle machine** (2026-06-18, 1-min load < 1) — a single `hyperfine` invocation per tier so
every row, baselines included, sees the same machine state and the same current corpus
(startup on `README.md`; scans on navidrome 29M / immich 420M; `-M 30/10/6`). Two fairness
fixes are folded in: **all three JVM languages launch under identical bare `java`** (no
per-language `-XX` tuning — an earlier cut gave Kotlin `-XX:+UseSerialGC -XX:TieredStopAtLevel=1`,
which flattered it; removing it is why Kotlin·tuned jumped 103→249 ms), and **OCaml is built
with an opam flambda switch + `-O3`** (the stock compiler is non-flambda, where `-O3` is a
no-op). These are newer than the multi-repo geomean tables higher up and use a different
corpus snapshot, so don't cross-compare the two; within each table below the numbers are
directly comparable.

### Startup tax — search one small file (`README.md`, pattern `the`, 20 runs)

This is the whole story for managed runtimes on small jobs:

| impl | mean ms | vs asm |
|---|--:|--:|
| asmgrep | 0.20 | 1.0× |
| **FreePascal·std** | 0.41 | 2.1× |
| C·std | 0.49 | 2.5× |
| **Odin·std** | 0.59 | 2.9× |
| **Ada·std** | 0.60 | 3.0× |
| **Fortran·std** | 0.80 | 4.0× |
| Rust | 0.85 | 4.2× |
| **OCaml·std** (flambda) | 1.02 | 5.1× |
| Go | 1.05 | 5.2× |
| **Common Lisp·std (SBCL)** | 3.35 | 17× |
| **Haskell·std (GHC)** | 16.1 | 81× |
| **Java·std** | 30.5 | 152× |
| **Kotlin·std** | 41.2 | 206× |
| **Clojure·std** | 438 | 2189× |

**Odin starts like a native binary** (sub-ms, in the C/Zig band). The surprise is
**SBCL: ~3.4 ms** — 10× faster to start than the JVM, because a saved Lisp image is a
*native executable*, not a VM bootstrapping its runtime + classloader + JIT. The JVM
trio pays ~30–40 ms of fixed launch before touching a byte; **Clojure adds ~0.45 s of
runtime init** (interning `clojure.core` etc.) even fully AOT-compiled.

### Idiomatic single-threaded scan — `-ri error navidrome` (29M, 8 runs)

| impl | mean ms | vs best |
|---|--:|--:|
| grep | 15.3 | 1.0× |
| C·std | 31.0 | 2.0× |
| Zig·std | 33.4 | 2.2× |
| Go | 47.1 | 3.1× |
| **Odin·std** | 53.6 | 3.5× |
| **Fortran·std** | 54.5 | 3.6× |
| **FreePascal·std** | 68.1 | 4.5× |
| **Common Lisp·std** | 82.2 | 5.4× |
| **OCaml·std** (flambda) | 88.6 | 5.8× |
| **Haskell·std** | 97.4 | 6.4× |
| **Ada·std** | 115 | 7.5× |
| **Java·std** | 191 | 12.5× |
| **Kotlin·std** | 201 | 13.2× |
| **Clojure·std** | 601 | 39× |

Idiomatic **Odin sits right in the C/Zig/Go idiomatic cluster** (~2–3.5×) — confirming
"within the compiled tier the language is irrelevant" now extends to Odin. SBCL is a tier
back but respectable for a dynamic language. The JVM trio is still launch/warmup-bound here:
the job finishes (~tens of ms of actual work) before the JIT compiles the hot loop.

(**Rust** has no single-threaded entry: the implementation here is `walkdir`+`rayon`+`memchr`,
*parallel by default* — it only fits the tuned-MT table below, where it leads the idiomatic
field at 6.9 ms / navidrome, 15.1 ms / immich.)

### Tuned-MT scan (reused buffer + prefix binary-check), with baselines

`-ri error`, mean ms:

| impl | navidrome 29M | immich 420M |
|---|--:|--:|
| asmgrep | 3.0 | 7.9 |
| Rust·mt | 7.0 | 15.0 |
| Zig·mt | 7.9 | 22.5 |
| ripgrep | 8.2 | 12.3 |
| C·mt | 9.2 | 22.8 |
| Go·mt | 10.8 | 29.8 |
| GNU grep | 15.4 | 47.8 |
| **Fortran·tuned** | 20.4 | 47.4 |
| **Common Lisp·tuned** | 23.1 | 54.1 |
| **OCaml·tuned** (flambda) | 23.5 | 64.8 |
| **Odin·tuned** | 30.7 | 135 |
| **Ada·tuned** | 33.5 | 97.8 |
| **FreePascal·tuned** | 39.2 | 118 |
| **Haskell·tuned** | 67.8 | 172 |
| **Kotlin·tuned** | 249 | 413 |
| **Java·tuned** | 277 | 325 |
| **Clojure·tuned** | 578 | 625 |

Two findings here:

1. **Native-image SBCL is genuinely competitive** — tuned-MT Common Lisp lands 23/54 ms,
   within ~1.2–1.5× of GNU grep (and Fortran's `index()`-backed tuned variant actually *ties*
   grep: 20.4/47.4 ms vs 15.4/47.8 ms). A *dynamic* language with real threads (`sb-thread`)
   and a native saved image performing in the same class as grep is the surprise of the batch.
2. **Parallelism cannot rescue a startup-bound runtime.** For the JVM the tuned-MT variant is
   *worse than its single-threaded variant* on these jobs — Java 277 vs 191 ms, Kotlin 249 vs
   201 ms (navidrome). Adding threads to a job that finishes before the JIT warms up just buys
   you thread-pool spin-up + extra GC/JIT-compiler threads competing for the same short window,
   on top of per-file object/syscall overhead (worst on file-count-heavy immich). You can't bolt
   threads onto a 30–440 ms fixed launch cost. (This is also why the bare-`java` fix matters:
   Kotlin's earlier `-XX:+UseSerialGC -XX:TieredStopAtLevel=1` *suppressed* exactly those extra
   threads, halving its tuned time to 103 ms and masking the effect — the fair number is 249 ms.)
   Odin·tuned also scaled poorly (1.7×, not 6×): its idiomatic walker/threading does more
   per-file work than the C/Zig tuned versions.
3. **Haskell can't *do* the memory pillar — by language design.** It's natively compiled (GHC)
   with a fast-ish startup (~16 ms, between SBCL's native image and the JVM), but its scan is
   slow (~97 ms single-threaded / navidrome) and barely scales under the threaded RTS
   (~1.4×, 97→68 ms). The reason ties straight back to pillar 2: `ByteString` is **immutable**,
   so the per-thread reused-buffer optimization is unidiomatic and unsafe (a `Builder` from one
   file would alias the buffer the next `hGetBuf` overwrites). The tuned variant could only ship
   the prefix-check, not buffer reuse — so Haskell is structurally pinned in the allocation-heavy
   regime that caps the other idiomatic versions at ~1.5× threading. Immutability is a real
   ergonomic and correctness win that costs you exactly the lever this experiment found matters most.
4. **OCaml and FreePascal: native startup, *can* do the memory pillar — but pay an algorithm tax.**
   Both compile to native (FreePascal startup **0.41 ms** ≈ C, OCaml 1.02 ms), and both have
   *mutable* buffers (`Bytes` / dynamic arrays), so the tuned variant does genuine per-worker
   buffer reuse and actually scales (OCaml 89→24 ms, ~3.8× on Domains; FreePascal 68→39 ms).
   But their idiomatic single-threaded scan is *slow* (~68–89 ms / navidrome, slower than Go/Odin)
   for one reason: **neither stdlib ships a substring search**, so both hand-roll a scalar
   byte loop — no SIMD `memmem`/`bytes.Index`. **The flambda experiment nails this down:** building
   OCaml with a flambda switch + `-O3` (aggressive inlining) bought only ~9% on the scan (97→89 ms
   vs the stock non-flambda compiler) — proving the cost is the *scalar algorithm*, not missing
   compiler optimization. The gap is the **algorithm**, not the language, the same lesson as the
   original "naive C" blowup. (OCaml's `Domain`-based parallelism is the clean OCaml-5 story;
   FreePascal needed `BeginThread` instead of `TThread.WaitFor`,
   whose join spins a fixed ~100 ms futex timeout — a 100 ms floor on every threaded run until fixed.)
5. **Ada and Fortran round out the native tier — and Fortran's `index()` proves the algorithm point.**
   Both compile native with sub-ms startup (Ada **0.60 ms**, Fortran 0.80 ms) and both do real
   buffer reuse (Ada per-task `Worker_State` records on tasks + protected objects; Fortran
   per-thread `worker_t` slots under OpenMP), so both scale on the tuned tier (Ada 115→34 ms, ~3.5×;
   Fortran 55→20 ms, now the fastest new language and tied with grep).
   The instructive split is single-threaded: **Ada 115 ms vs Fortran 55 ms**. Ada hand-rolls a
   scalar `Byte_Index` (like OCaml/FreePascal); **Fortran uses its built-in `index()` intrinsic**,
   a real substring search, and is ~2× faster for it. Same native backend (both GCC) — the only
   difference is *whether the stdlib handed you a fast search*, the algorithm pillar one more time.
   (Fortran has no standard directory API, so the recursive walk is hand-bound POSIX
   `opendir`/`readdir`/`lstat` via `iso_c_binding` — a reminder that "idiomatic" varies wildly:
   in Go the walk is one stdlib call, in Fortran it's ~60 lines of C-struct-offset interop.)

**Refined thesis.** "The language barely matters" holds *within the natively-compiled tier*
— asm ≈ C ≈ Zig ≈ Odin, and even SBCL via a native image is close. It **breaks for managed
runtimes on short-lived CLI work**: there the *runtime model* (AOT native image vs a
bootstrapping VM) dominates the algorithm and even the parallelism pillar. For a grep — a
process that launches, scans, and exits in milliseconds — JVM startup is a structural floor
no in-program engineering removes, and Clojure's runtime-init constant puts it in a class of
its own (~0.5 s before any repo is large enough to amortize it).

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
