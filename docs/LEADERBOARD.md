# 🏁 The complete leaderboard — 48 implementations, one harness

Every language implementation in this repo (best shipped variant) ranked against **GNU grep** on a single
unified harness and a **pinned, public corpus**. This is the canonical, comprehensive board; the README's
inline tables are excerpts.

- **Task:** `-r -i error` (recursive, case-insensitive, fixed-string) over a 6-repo source tree.
- **Baseline:** GNU grep `-rIiF`, same run, same corpus. `×grep` is the geometric mean of
  `mean(impl) / mean(grep)` over the repos that completed. **`×grep < 1` means *faster than GNU grep*.**
- **Corpus (pinned, `tests/corpus.lock`):** camilladsp · jellyfin · navidrome · onyx · immich · jdk
  (size-ordered; jdk is the heavyweight, GNU grep ≈ 872 ms on it).
- **Harness:** `tests/leaderboard.sh`. Fast (impl, repo) pairs get hyperfine precision; slow ones use a
  single bounded run. Per-(impl, repo) timeout 300 s — a repo that exceeds it is excluded from that
  impl's geomean and marked `slow:<repo>`. Correctness gate: a result counts only if its match-line count
  equals GNU grep's (`LC_ALL=C`, byte-level — see [BENCHMARKING.md](BENCHMARKING.md)).
- **Machine:** i5-8400 (6 cores, AVX2), CPU governor `performance`.
- **Run:** 2026-06-23, 48 impls, total wall-clock 30.0 min.

**Correctness:** this run is the first with every implementation **byte-exact vs GNU grep on every repo it
completes** — a correctness pass fixed 5 impls that previously diverged (Common Lisp, Ada, Fortran, J,
Raku; see the commit history for root causes: wildcard-pathname opens, a 1.5 GB `.git` pack overflowing
buffers, worker-stack overflow, symlink double-counting, and CRLF grapheme drift). Only **Red** falls short
of 6/6 — it genuinely exceeds the 300 s gate on jdk (a speed limit, not a wrong answer).

`startup` = mean run on a single small file (boot-dominated, no scan). `repos` = how many of the 6
passed the correctness gate.

| # | language | variant | ×grep | startup | repos | runtime model / notes |
|--:|---|---|--:|--:|:--:|---|
| 1 | **asm** | hand-SIMD | **0.19×** | 0.2 ms | 6/6 | freestanding x86-64 + AVX2; no libc |
| 2 | **C** | hand-SIMD | **0.20×** | 0.6 ms | 6/6 | AVX2 scan |
| 3 | **Zig** | hand-SIMD | **0.21×** | 0.5 ms | 6/6 | AVX2 scan |
| 4 | **Rust** | idiomatic | **0.39×** | 0.9 ms | 6/6 | walkdir + rayon + memchr |
| 5 | **Zig** | idiomatic, MT | **0.50×** | 1.7 ms | 6/6 | std lib, threads |
| 6 | **C** | idiomatic, MT | **0.57×** | 0.7 ms | 6/6 | threads |
| 7 | **C++** | tuned, MT | **0.61×** | 1.3 ms | 6/6 | idiomatic Modern C++23, tuned |
| 8 | **Go** | goroutines | **0.68×** | 1.1 ms | 6/6 | native |
| 9 | **LuaJIT** | tuned, MT | **0.87×** | 2.1 ms | 6/6 | tracing JIT, `fork` |
| – | _GNU grep_ | _baseline_ | _1.00×_ | – | – | _reference denominator_ |
| 10 | **Fortran** | tuned, MT | 1.08× | 1.1 ms | 6/6 | OpenMP |
| 11 | **Common Lisp** | tuned, MT | 1.35× | 3.7 ms | 6/6 | SBCL native image |
| 12 | **GraalVM** | native-image | 1.36× | 2.5 ms | 6/6 | AOT-compiled Java — no JVM tax |
| 13 | **OCaml** | tuned, MT | 1.40× | 1.0 ms | 6/6 | native, Domains |
| 14 | **Ada** | tuned, MT | 2.22× | 0.9 ms | 6/6 | native tasks |
| 15 | **Free Pascal** | tuned, MT | 2.39× | 1.2 ms | 6/6 | native |
| 16 | **Swift** | tuned, MT | 2.60× | 2.6 ms | 6/6 | native + ARC |
| 17 | **Pony** | tuned, MT | 2.72× | 5.4 ms | 6/6 | native actor model |
| 18 | **D** | tuned, MT | 2.77× | 1.0 ms | 6/6 | native + GC |
| 19 | **Odin** | tuned, MT | 2.90× | 2.6 ms | 6/6 | native |
| 20 | **Crystal** | tuned, MT | 3.06× | 3.9 ms | 6/6 | native + GC |
| 21 | **Chapel** | tuned, MT | 3.09× | 23.1 ms | 6/6 | HPC `forall`; qthreads boot |
| 22 | **Nim** | tuned, MT | 3.21× | 0.9 ms | 6/6 | native (compiles to C) |
| 23 | **Bun** | tuned, MT | 4.63× | 39.4 ms | 6/6 | JS/TS runtime (JavaScriptCore) |
| 24 | **C#** | NativeAOT | 4.93× | 1.5 ms | 6/6 | AOT, no JIT/JVM |
| 25 | **Go** | idiomatic | 5.17× | 1.1 ms | 6/6 | single-threaded |
| 26 | **Codon** | std | 5.84× | 5.1 ms | 6/6 | Python *syntax* → native (LLVM AOT) |
| 27 | **Python** | tuned, MT | 5.99× | 26.6 ms | 6/6 | CPython, multiprocessing |
| 28 | **Perl** | std | 6.19× | 4.3 ms | 6/6 | interpreted, C-backed `index` |
| 29 | **Clojure-native** | tuned, MT | 6.45× | 2.5 ms | 6/6 | GraalVM native-image (AOT'd Clojure) |
| 30 | **Node.js** | tuned, MT | 6.46× | 67.5 ms | 6/6 | V8, `worker_threads` |
| 31 | **Haskell** | tuned, MT | 6.69× | 15.3 ms | 6/6 | GHC native + RTS |
| 32 | **Rust → WASI** | std | 7.78× | 12.0 ms | 6/6 | `wasm32-wasip1` under wasmtime (sandbox tax) |
| 33 | **Ruby** | std | 7.99× | 42.4 ms | 6/6 | CRuby, C-backed `String#index` |
| 34 | **J** | std | 8.78× | 47.9 ms | 6/6 | array lang; `E.` is a C primitive |
| 35 | **Scala-Native** | std | 9.79× | 1.8 ms | 6/6 | LLVM AOT — no JVM |
| 36 | **Java** | tuned, MT | 9.94× | 32.6 ms | 6/6 | JVM — startup-bound |
| 37 | **Dart** | std | 10.68× | 2.3 ms | 6/6 | native self-contained exe |
| 38 | **PyPy** | std | 11.32× | 48.2 ms | 6/6 | the unchanged CPython source under a tracing JIT |
| 39 | **Kotlin** | tuned, MT | 11.60× | 42.0 ms | 6/6 | JVM — startup-bound |
| 40 | **Dyalog APL** | std | 19.87×† | 283.8 ms† | 6/6 | canonical APL; C-backed `⍷` scan but **startup-bound** |
| 41 | **Deno** | tuned, MT | 20.89× | 69.8 ms | 6/6 | JS/TS runtime (V8) |
| 42 | **Clojure** | tuned, MT | 23.04× | 405.9 ms | 6/6 | JVM AOT — startup-bound |
| 43 | **awk** | std | 23.80× | 2.4 ms | 6/6 | interpreted (gawk) |
| 44 | **Julia** | tuned, MT | 27.80× | 603.3 ms | 6/6 | JIT — startup + compile tax |
| 45 | **Elixir** | tuned, MT | 34.65× | 417.2 ms | 6/6 | BEAM — startup-bound |
| 46 | **Bash** | std | 170.50× | 2.7 ms | 6/6 | pure shell; no concurrency primitive |
| 47 | **Raku** | std | 346.18× | 426.9 ms | 6/6 | MoarVM — now byte-exact incl. CRLF, and finishes jdk |
| 48 | **Red** | std | 705.99× | 17.8 ms | 5/6 | Rebol-family, interpreted — `slow:jdk` (exceeds 300 s) |
| – | **Forth** | std | **DNF** | 6.0 ms | 0/6 | gforth; interpreted byte-at-a-time scan exceeds the 300 s gate on every repo (excluded from the timed run; the bottom of the board) |

**† Dyalog caveat:** this row predates the `ENABLE_CEF=0` fix. Dyalog 19 on Linux was booting a CEF/Chromium
process tree at startup (for its HTMLRenderer GUI) even for this headless script; disabling it cut startup
**283.8 ms → ~53 ms** with byte-identical output. Dyalog is startup-bound, so its real `×grep` is now far
better than 19.87× — it will be re-measured on the next full run.

**Variant suffixes:** `std` = idiomatic single-pass; `MT` = +threads; `tuned` = +buffer-reuse / chunking.
A language ships only `std` when its runtime offers no idiomatic shared-memory parallelism (interpreters
launched per-process, array langs) — the *absence* of an MT row is itself a data point.

## How to read it

**Nine implementations beat GNU grep**; top-to-bottom the spread is ~3,700×, and it sorts almost entirely
by **runtime model, not language syntax**:

- **Top tier** — hand-SIMD natives (asm/C/Zig) and the idiomatic-tuned native cluster (Rust, C++, Go,
  LuaJIT) bottom out in a C/SIMD scan loop and amortize ~sub-ms startup.
- **Same scan, opposite placement.** J's `E.` and Dyalog's `⍷` are *both* C primitives (fast scans), yet
  J lands near the natives (#34) while Dyalog (#40) drops into the startup-bound tier — sorted apart by a
  big interpreter boot alone. (GNU APL was attempted for the array slot but couldn't pass the harness
  on this machine's broken `gnu-apl 1.9-1` build — see [RESULTS.md](RESULTS.md); J and Dyalog represent it.)
- **Startup-bound tail.** The JVM/JIT/BEAM runtimes (Java, Kotlin, Clojure, Julia, Elixir) sit low because
  on a 6-repo tree their boot is a large share of total time; on a *large* tree the scan amortizes their
  boot and they climb sharply.
- **Interpreted floor.** Bash, Raku, Red, and (off the board) Forth scan byte-at-a-time in the interpreter
  — the only tier where the *language* genuinely caps throughput.

`×grep` is corpus-sensitive (it's a ratio to grep on *this* tree), so read the **ordering**, not the
absolute multiplier. Full methodology: [BENCHMARKING.md](BENCHMARKING.md). Raw run log: `leaderboard_final.txt`.
