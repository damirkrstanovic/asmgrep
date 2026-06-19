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

## Two more: D and C# (2026-06-19)

Two more *compiled* languages — but the interesting contrast turned out to be scan-codegen
quality, not native-vs-managed. Each in the same three tiers:

- **D** (`d/`, `dmd -O -release -inline` → native binary with a GC runtime) — the C/Zig/Odin/
  FreePascal cluster; reference compiler, hand-rolled scalar scan (no stdlib `memmem`).
- **C#** (`csharp/aot/`, **.NET 10 NativeAOT**, `dotnet publish -p:PublishAot` → a true native
  ELF, no VM) — RyuJIT-quality AOT codegen + the BCL's vectorized `ReadOnlySpan<byte>.IndexOf`.

All 6 are byte-for-byte identical to `grep` (`tests/verify_impl.sh`, 16 cases each = 96/96).

*Directional numbers* (warm cache, `-ri error /usr/include`, 96k files, i5-8400 6-core — a
**different corpus** from the tables above, so compare the columns to each other, not across
sections; startup is the single-file figure):

| implementation | startup | std | +threads | +tuned | vs grep (0.92 s) |
|---|--:|--:|--:|--:|--:|
| **D** | 0.8 ms | 5.96 s | 2.20 s | **1.18 s** | 1.3× |
| **C#** (NativeAOT) | 1.6 ms | 2.52 s | 2.52 s | 2.52 s | ~2.7× |

1. **D confirms the native thesis once more.** Sub-ms startup (0.8 ms, in the C/Zig/Pascal
   band), and because D's arrays are *mutable* the buffer-reuse pillar applies: tuned-MT scales
   ~5× over single-threaded (5.96 → 1.18 s) and lands within ~1.3× of GNU grep. The
   single-threaded scan carries the now-familiar hand-rolled-search tax (no stdlib `memmem`).
2. **C# (NativeAOT) does the *least total work* of anything here — and that's why threading is
   moot.** Sub-2 ms startup (true native ELF, no VM). Its three tiers are a **dead heat** (std =
   naive-mt = tuned-mt = 2.52 s) at ~100% of *one* core — not because threading is broken (a
   pure-CPU probe scales 6 threads ≈ 1×), but because the vectorized `Span.IndexOf` scan made the
   program **stop being scan-bound**. The decisive test — 454 MB across 12 big files (trivial
   walk), case-sensitive (no lowercase pass):

   | impl | wall | user (CPU) | reading |
   |---|--:|--:|---|
   | **C#-AOT std** | 189 ms | **77 ms** | scan = 5.9 GB/s, only ~40% of wall; the rest is `read()` syscall time (113 ms sys) |
   | **C#-AOT tuned-mt** | 187 ms | 77 ms | identical — nothing left to parallelize |
   | **D tuned-mt** | 259 ms | **610 ms** | genuinely uses ~4 cores, yet *slower* — its scalar scan burns **8× the CPU** |
   | GNU grep | 329 ms | 287 ms | single-threaded |

   So NativeAOT C# scans 454 MB in **77 ms of CPU**, lands *ahead of D* and near grep, and "can't
   parallelize" only because — exactly like grep itself — a SIMD scan turns this into an I/O-bound
   job. The memory pillar is moot here: with a vectorized scan, **I/O / per-file syscall overhead
   is the floor**, just as it is for the native C/Zig tier. Within AOT, swapping the SIMD scan
   back for the same hand-rolled scalar loop (the `#if HANDROLLED` control in `csharp/aot/Common.cs`)
   costs ~1.6× (2.52 → 4.09 s on `/usr/include`) — confirming the *algorithm*, not the runtime,
   was the remaining gap. Built with `make csharp-aot` (needs `dotnet-sdk` + clang/lld);
   `csgrep_aot_std{,_mt,_mt_tuned}`.

## One more: C++ (idiomatic Modern C++23) (2026-06-19)

The question this time was deliberately *not* "is C++ fast" (it's native, of course it
is) but **what does idiomatic C++ cost vs idiomatic C** — written as real **Modern C++23**,
not "C with `std::`". Same three tiers (`cpp/grep_std.cpp`, `grep_mt.cpp`, `grep_mt_tuned.cpp`),
all leaning into the heavier idioms on purpose:

- **walk:** `std::filesystem::recursive_directory_iterator` (not `nftw`/`opendir`)
- **read:** `std::ifstream` + `fs::file_size`, errors flowing through `std::expected<…,std::errc>`
- **scan:** `std::string_view::find` — libstdc++'s `memchr`/`memcmp`-backed search, the idiomatic
  analogue of `memmem` (Boyer-Moore-Horspool was rejected: 4× slower on short patterns)
- **output:** `std::format_to` into a per-thread `std::string`, `std::print` to flush
- **parallel:** a `std::jthread` pool + `std::atomic<size_t>` work index; tuned worker reuses one
  `std::vector<char>` per thread + reads a 64 KB prefix, binary-checks it, reads the rest only if
  not binary

All 3 are byte-for-byte identical to `grep` (`tests/verify_impl.sh`, 16 cases each = 48/48).
Built with `make cpp` (`g++ -O2 -std=c++23`, `-pthread` for the MT variants).

### Where the idiomatic-C++ tax actually was (it's not the abstractions)

The *first* cut of cpp·std came in **1.33× slower than idiomatic C** (22.3× vs C's 16.8× on asm),
and the obvious story — "high-level abstractions cost you" — turned out to be **wrong**. `perf` is
sandbox-restricted here, so attribution was done two ways. First, `time`-split over 30 runs on
immich showed the gap is **user CPU, not syscalls**: C `user=1.29s sys=5.07s`, C++
`user=3.19s sys=5.85s` — system time (kernel I/O) is the same; C++ burns **2.5× the user CPU**.
(strace confirms C++ even makes *fewer* syscalls — 15k vs 27k — C's `fopen`/`fseek`/`ftell`/`rewind`
dance generates a pile of `lseek`/`fstat`.)

Then a compile-time ablation (one source, each idiom toggled back to its C form; immich `-ri error`,
**user CPU**, 30 runs) located it precisely:

| variant | what changed from shipped C++ | user s |
|---|---|--:|
| baseline | shipped idioms | 3.20 |
| swap `format_to` → `string::append` | output formatting | 3.08 |
| swap `ifstream` → `fopen`/`fread` | read mechanism | 3.25 |
| swap `recursive_directory_iterator` → `nftw` | the walk | 3.18 |
| swap `string_view::find` → `memmem` | the scan | 3.03 |
| swap `ranges::transform` → C `for` | the `-i` lowercase | 3.31 |
| **drop the `vector::resize` zero-fill** | buffer allocation | **1.72** |
| *all five idioms → C, but keep `resize`* | — | 3.29 |
| *all five → C, **and** no zero-fill* | — | 1.80 |
| C reference (`cgrep_std`) | — | 1.28 |

**The entire gap was `std::vector<char>::resize(sz)`.** It value-initializes — a full-buffer
`memset` to 0 — and then `read()` immediately overwrites every byte, so the idiomatic `vector`
writes each file's bytes **twice**. That one line was **~1.5 s of the ~1.9 s user-CPU gap (≈78%)**.
Swapping *all five* high-level idioms to their C forms while keeping the `resize` stays at 3.3 s;
keeping every idiom but killing the zero-fill drops to 1.7 s. `std::filesystem`, `std::ifstream`,
`std::format_to`, `std::ranges::transform` are **collectively ~free** here; `string_view::find` is
the only one with a measurable (small, ~6%) edge for `memmem`. (The `-i` path actually has *two*
such double-writes — the read buffer and the lowercased copy — both fixed below.)

**The fix is itself idiomatic modern C++:** non-zeroing allocation is exactly what
`std::make_unique_for_overwrite<char[]>` (C++20, the read buffer) and
`std::string::resize_and_overwrite` (C++23, the lowercase buffer) are *for*. With both applied to
the per-file-allocating variants (std + naive-mt; the tuned variant's reused buffer only grows, so
it pays the zero-fill once during warmup and never needed it):

| impl | navidrome | cognee | onyx | immich | geo vs asm | vs C |
|---|--:|--:|--:|--:|--:|--:|
| asm | 3.52 | 5.03 | 5.27 | 11.17 | 1.00× | — |
| **cpp·std** | 33.7 | 101 | 120 | 216 | **17.1×** | **1.04× C·std** |
| C·std (ref) | 31.8 | 97.2 | 119 | 208 | 16.5× | — |
| **cpp·mt** (naive) | 13.0 | 72.7 | 84.7 | 156 | **10.5×** | — |
| **cpp·tuned** | 10.5 | 18.1 | 17.4 | 26.8 | **3.03×** | 1.10× C·tuned |
| C·tuned (ref) | 9.69 | 15.7 | 16.5 | 24.2 | 2.76× | — |
| grep | 15.4 | 24.4 | 27.5 | 47.6 | 4.66× | — |

(The two runs have slightly different absolute baselines — warm-cache noise — so compare via the
geomean-vs-asm column. The `for_overwrite` change moved cpp·std from **1.33× → 1.04× of idiomatic
C**, and dropped naive-mt 14.1× → 10.5×.)

1. **C++ lands exactly in the native compiled tier — and now ties idiomatic C at *every* tier.**
   cpp·std ≈ C·std (1.04×), cpp·tuned 3.03× ≈ C·tuned 2.76×, **beating GNU grep (4.66×) by ~1.5×**.
   The thesis "within the compiled tier the language is irrelevant" extends cleanly to C++: the
   scans are the same glibc primitives, and once the buffer handling matches, so does the speed.

2. **The "idiomatic-C++ tax" was a hidden `memset`, not the abstractions.** The high-level idioms
   that *look* expensive (`filesystem`, `ifstream`, `format_to`, ranges) cost almost nothing; the
   expensive thing was the most innocent-looking line in the program — a container `resize`. The
   lesson generalizes past grep: in C++ the default-construct/zero-initialize behavior of the
   standard containers is the performance trap, and the `for_overwrite` family is the escape hatch.

3. **The memory pillar reproduces cleanly, again.** Bolting `std::jthread` onto the
   allocate-per-file code (cpp·mt) recovers far less than 6× — immich 216 → 156 ms — even after the
   zero-fill fix, because per-file allocation still serializes on page faults under the kernel
   page-table lock. Reuse-one-buffer + prefix-check (cpp·tuned) then takes 10.5× → 3.03× — the same
   memory-pillar jump seen in every other language, with no algorithm or scan change.

## The scripting + JIT tier: Python, gawk, LuaJIT, JavaScript (2026-06-19)

Four more languages — but these open **two whole tiers below the compiled cluster** the experiment
hadn't sampled: **interpreted** (CPython, gawk) and **JIT-scripting** (LuaJIT, JS on V8/JSC). They
sort by runtime model even more starkly than the compiled languages did — the spread here is **~200×**,
from LuaJIT tying grep to gawk three orders of magnitude behind.

A design note that is itself a finding: the three-variant template (`_std`/`_mt`/`_mt_tuned`) **does
not map onto every runtime**, and *how* it fails to map is informative. gawk has no threads and no
shared memory → `_std` only. CPython's GIL means threads can't parallelize a CPU scan → `_mt` is
`multiprocessing` (fork + pickle + IPC). LuaJIT has no threads → `_mt` `fork()`s a worker pool, each
child `flock()`-guarding its output write (the cross-process analogue of the C mutexed flush). Node's
`worker_threads` is the only one that maps cleanly to the C model. All byte-for-byte identical to
`grep` (`tests/verify_impl.sh`: 192/192 across the 12 launchers; gawk is `_std`-only).

**Startup** (search `the` in one small file; the repo's other rows for scale: FreePascal 0.41 ms,
C# 1.6 ms, SBCL 3.4 ms, Java/Kotlin 30–41 ms, Clojure ~450 ms):

| runtime | startup | tier |
|---|--:|---|
| **LuaJIT** | 2.6 ms | native-class, no warmup |
| **gawk** | 3.7 ms | cheap interpreter boot |
| **CPython 3.14** | 15.4 ms | ≈ Haskell's RTS |
| **bun** (JSC) | 24 ms (8.6 ms bare `-e0`) | below the JVM |
| **node** (V8) | 37 ms (32 ms bare) | JVM band |
| **deno** (V8) | 44 ms (33 ms bare) | JVM band |

**Scan** (warm cache, `-ri error`, one hyperfine harness, mean ms; gawk from a separate run, it's
~200× regardless):

| impl | navidrome | cognee | immich | geomean vs grep |
|---|--:|--:|--:|--:|
| grep | 15.8 | 24.8 | 49.0 | 1.0× |
| **LuaJIT** tuned | 16.6 | 31.2 | 50.7 | **1.1×** |
| LuaJIT std | 52.0 | 207 | 487 | 6.5× |
| **JS/node** tuned | 113 | 116 | 126 | 4.4× |
| JS/node std | 134 | 264 | 537 | 10.0× |
| **Python** std | 64.1 | 140 | 284 | 5.1× |
| Python tuned-MT | 178 | 188 | 212 | 7.2× |
| **gawk** std | 1316 | 6977 | 17364 | ~200× |

1. **LuaJIT ties grep — but NOT because of the JIT (we checked, and the obvious story is wrong).**
   The tuned variant ties grep (1.1× geomean, immich 50.7 vs 49.0 ms) at **2.6 ms startup**. The
   tempting claim — "the trace-JIT compiles the hot scan to native code" — is **false**: turning the
   JIT fully off (`luajit -joff`, which drops to LuaJIT's *assembly* interpreter) changes the time by
   **1.01× (std) / 1.03× (tuned)** — nothing. `string.find(...,plain=true)` is a C fast-function
   (`lj_str_find` → `memchr`/`memcmp`); the JIT's recorder emits an IR *call* to it, never its own
   byte-scan loop (`-jv` confirms: only the walk + line-locate *glue* gets traced). So the scan is C
   with or without the JIT — exactly like CPython's `bytes.find`. What actually puts LuaJIT in the
   native cluster is (a) **2.6 ms startup** (so forking is cheap) and (b) its *idiomatic* parallelism
   being `fork()` — near-zero overhead. The pillars still dominate: `_std` is 6.5× grep (faults in
   big blobs), and only the 64 KB-prefix `_mt_tuned` closes the gap (Lua strings are immutable, so
   only the "don't read what you'll skip" half of pillar 2 maps — that alone is enough).

2. **JavaScript: V8/JSC do NOT inherit the JVM's startup tax uniformly — but only `bun` escapes it.**
   node ~32 ms and deno ~33 ms bare are squarely in the Java/Kotlin band; **bun is 8.6 ms** — the one
   runtime that breaks out, same source, only the engine differs (the cleanest startup sub-story
   here). Crucially, **unlike the JVM rows, JS scales with threads**: `worker_threads` tuned-MT lands
   at 4.4× grep (immich 126 ms) while naive threading gains ~nothing — pillar 2 reproduced in a
   managed runtime, because `Buffer` is mutable and V8 JITs the long scan loop.

3. **Python: the scan is C too, and its parallel "loss" was the *library*, not the language.**
   `pygrep_std` is competitive (64 ms navidrome, 5.1× grep geomean) because `bytes.find`/`bytes.translate`
   are C beneath the interpreter (`FASTSEARCH`: memchr / BMH-skip / two-way), leaving a flat ~15 ms
   boot + per-file glue. The GIL forces `_mt` onto `multiprocessing`, and the shipped `Pool` variant
   *regresses* — slower than single-threaded except on the largest tree. But that is **`Pool` pickling
   every result back over a pipe to the parent**, not Python being slow. Swapping *only* the primitive
   to a raw `os.fork` pool — shared-nothing file slices, each child writing its own stdout under an
   `flock`, zero IPC (LuaJIT's exact model) — measures the cost of the IPC directly:

   | immich / cognee (`-ri error`, ms) | grep | `multiprocessing.Pool` (shipped) | `os.fork` (no IPC) | LuaJIT tuned |
   |---|--:|--:|--:|--:|
   | cognee | 23.6 | 169 | **42.3** | 28.4 |
   | immich | 46.9 | 190 | **59.3** | 46.3 |

   The `fork` pool is **3–4× faster than `Pool`** and ties LuaJIT / lands ~1.3× of grep — so
   Python-the-language was never the problem; `Pool.imap` shipping 7301 pickled result-lines through a
   pipe was. (CPython docs literally advise "better to inherit than pickle/unpickle".) We keep the
   `multiprocessing` variant shipped because it *is* idiomatic Python parallelism; the `os.fork` run is
   the ablation that attributes the gap — and a free-threaded 3.14 build would sidestep it a third way
   (real threads, one address space).

**The meta-finding for this whole tier:** the scan is C in every scripting language and the
JIT/interpreter is irrelevant to it (LuaJIT `-joff` = 1.01×; CPython's scan never runs bytecode).
What *sorted* the tier was **which concurrency primitive is idiomatic** — LuaJIT's `fork()` is nearly
free, Python's `multiprocessing.Pool` pickles results over pipes, gawk has none at all — not the
language and not the JIT. The same "it's never the thing you'd first credit" lesson as the C++
`memset`, generalized: across compiled *and* scripting tiers, performance tracks the
parallelism + I/O strategy, and the language barely matters.

4. **gawk is the floor — and proves "right tool for the job" loses to runtime model.** The one
   language here built for exactly this (`index()` is a literal substring search handed to you), yet
   it lands **80–350× behind grep** (1.3 s → 17 s as the tree grows). The gap isn't the algorithm —
   it's that every byte walks the interpreter loop with no SIMD, no mmap skip, and — fatally — **no
   concurrency story to recover the loss**, so the deficit *widens* with tree size. Startup is a
   non-issue (3.7 ms); it can only ever ship `_std`. A purpose-built DSL with the wrong runtime model
   still cannot out-run a worse-suited language with a better one — the project's thesis, in the
   extreme.

## GraalVM native-image: the loop-closer (2026-06-20)

The repo's sharpest claim is that the JVM rows (Java/Kotlin ~30–41 ms startup, tuned-MT *slower*
than single-threaded) are sunk by the **runtime model** — startup + JIT-warmup on a short-lived
process — not by the language or the code. GraalVM `native-image` lets us prove it directly: take the
**unchanged** `java/{GrepStd,GrepMt,GrepMtTuned}.java`, AOT-compile the same bytecode to a native ELF
(`native-image --no-fallback -march=native`, ~48 s/variant), and re-measure. Byte-for-byte identical
to grep (48/48). Same corpus/method as the JVM tables.

| | bare `java` | GraalVM native (same bytecode) | grep |
|---|--:|--:|--:|
| **startup** (README.md) | 30.6 ms | **2.4 ms** | — |
| cognee std | 317.3 | 258.1 | 23.9 |
| cognee **tuned-MT** | 278.5 (1.1× over std) | **43.6 (5.9×)** | 23.9 |
| immich std | 674.6 | 618.5 | 47.7 |
| immich **tuned-MT** | 380.9 (1.8×) | **65.9 (9.4×)** | 47.7 |

Two results, both from source that did not change a character:

1. **Startup 30.6 → 2.4 ms (12.7×).** The JVM boot/classload tax simply evaporates once the bytecode
   is AOT-compiled — GraalVM native lands in the sub-3 ms band with SBCL/LuaJIT, out of the JVM tier.
2. **The deeper one — threading goes from "barely helps" to "scales."** Under bare `java`, tuned-MT is
   only 1.1–1.8× its own single-threaded run (the recorded "JVM threads don't help on short jobs"
   result): on a process that lives ~300 ms the JIT never warms, so the scan runs cold (interpreted /
   C1) and the extra threads mostly contend. The *same code* under native-image ships the scan
   AOT-compiled from instruction one, so the threads parallelize real native work — tuned-MT scales
   **5.9–9.4×** over single-threaded and lands within ~1.4–1.8× of GNU grep.

So the JVM's entire poor showing was the **runtime** (startup + JIT-warmup on a short-lived process),
not the language and not the algorithm — recompile the identical bytecode ahead-of-time and it jumps
from the JVM tier straight into the native compiled cluster. This is the cleanest "language vs runtime"
separation in the repo: same `.java`, same `.class`, only the execution model changed. (Cost: the
native binaries are ~13.8 MB each — the SubstrateVM runtime is statically embedded, like SBCL's saved
images. Build needs the GraalVM JDK's `native-image`, which ships in the JDK dir, e.g.
`/usr/lib/jvm/java-25-graalvm-ce/bin`; `make graalvm GRAALVM_HOME=...` points at it.)

## Crystal and Elixir: native-with-GC vs the BEAM (2026-06-20)

Two more languages, both garbage-collected — and they land at *opposite ends* of the startup
spectrum, which is the whole point: GC isn't what sorts them, the runtime model is. All
byte-identical to grep (`tests/verify_impl.sh`, 96/96 across the 6 launchers).

| repo | Crystal std / mt / tuned | Elixir std / mt / tuned | grep |
|---|--:|--:|--:|
| navidrome | 53.6 / 23.9 / 24.5 | 921 / 644 / 624 | ~16 |
| cognee | 155 / 96.1 / 75.5 | 1362 / 1076 / 563 | ~25 |
| immich | 360 / 215 / 171 | 2287 / 1373 / 761 | ~49 |
| **startup** | **1.09 ms** | **~480 ms** | — |

1. **Crystal: Ruby syntax, LLVM-native — the D/SBCL "looks dynamic, runs native" story again.**
   `def`/blocks/`Array` read like Ruby, but `crystal build --release` emits a native ELF (over LLVM,
   with a GC) that starts in **1.09 ms** — squarely in the native cluster beside D (0.8 ms) and OCaml
   (1.0 ms), nowhere near a VM tax. Crystal's `Bytes` are *mutable*, so the buffer-reuse pillar
   applies: `_mt_tuned` reuses one read buffer + 64 KB-prefix-checks, and it visibly beats naive MT on
   the big trees (immich 171 vs 215 ms, cognee 75.5 vs 96.1) — landing **3.0–3.5× grep**. Real
   parallelism is the one wrinkle: Crystal fibers are single-threaded by default, so `_mt` needs
   `-Dpreview_mt` at build time and `CRYSTAL_WORKERS` at *runtime* (the binaries are wrapped in a
   launcher that sets it). The tuned variant trades the stdlib SIMD `String#byte_index` for a scalar
   search over the raw reused `Bytes` (Crystal `Slice` has no substring search) — the same memory-pillar-
   beats-scalar-scan-tax tradeoff as D/OCaml/Pascal.

2. **Elixir (BEAM): the exotic VM, and the slowest-starting runtime in the whole repo.** ~**480 ms**
   just to boot ERTS before a byte is searched — past even Clojure's ~450 ms, making it *the* startup
   floor of the set. The scan is fine: `:binary.match/2` is a C BIF, so the inner search is native and
   not the bottleneck; the cost is everywhere *around* it — ERTS boot, slurping files into immutable
   binaries, the byte-fold round-trip for `-i`, and per-file GC. `Task.async_stream` is the most
   idiomatic concurrency in the entire set (one line spreads files across all schedulers) and it does
   map the parallelism pillar (~1.4–1.7×), but **immutable binaries forbid the buffer-reuse half of
   pillar 2** (the Haskell constraint) — only the prefix binary-check half maps, and that's the biggest
   win here (`_mt_tuned` ~2× over `_mt` on binary-heavy trees: immich 761 vs 1373 ms, because it stops
   after one 64 KB read on `.git` packs). Net, the BEAM sits firmly in the bottom tier — 15–60× grep,
   dominated by startup and managed-runtime overhead.

The pair is the thesis in miniature: **two GC'd languages, ~440× apart on startup (1.09 ms vs 480 ms),
sorted entirely by runtime model** — native-AOT-with-GC vs a bytecode VM that boots a whole actor
runtime per invocation. GC was never the variable.

## Swift: a third memory model — ARC (2026-06-20)

Swift is native LLVM code (`swiftc -O`) but neither GC'd nor manually managed — it uses **ARC
(automatic reference counting)**, a third memory model. 48/48 vs grep.

| repo | std | mt | tuned | grep |
|---|--:|--:|--:|--:|
| navidrome | 43.6 | 25.1 | **13.6** | 15.6 |
| cognee | 183 | 158 | **69.1** | 24.4 |
| immich | 591 | 555 | **158** | 47.9 |

Startup **2.5 ms** — in the native cluster (two orders of magnitude below JVM/BEAM), just above C
(~0.5 ms) and D (~1.0 ms) only because the Swift runtime (`libswiftCore`/`libdispatch`) is
dynamically linked, not because of any per-process VM. The headline: **ARC doesn't block the memory
pillar.** A worker that owns its mutable `[UInt8]` and only grows it is the sole reference, so
copy-on-write never fires and the reused buffer + 64 KB prefix-check behaves exactly like the C/D
versions — the single biggest win, taking immich 591 → 158 ms (3.7×) by never faulting in big
binaries it then skips, and tuned-MT actually *beats* grep on navidrome (13.6 vs 15.6). Single-threaded
Swift trails the C/D cluster (navidrome 43.6 vs grep 15.6 ms) — ARC retain/release traffic and Array
bounds-checking surface here — but the gap is modest, not catastrophic, because the hot work runs in
`withUnsafeBufferPointer` over raw pointers and the scan is Glibc `memmem` (Foundation's
`Data.range(of:)` boxes bytes through Collection and is markedly slower — the idiomatic-but-slow trap,
avoided). One structural wrinkle: `_mt` uses GCD `DispatchQueue.concurrentPerform` (one closure per
file), but `_mt_tuned` drops to a fixed **pthread pool** — per-worker buffer ownership needs a stable
thread identity that GCD's transient task closures don't provide. So a third memory model, same result:
once buffer-reuse + parallelism are applied, Swift is grep-competitive; the language was never the
variable.

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
