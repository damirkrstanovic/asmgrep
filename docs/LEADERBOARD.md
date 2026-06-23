# 🏁 The complete leaderboard — 48 implementations, one harness

Every language implementation in this repo (best shipped variant) ranked against **GNU grep** on a single
unified harness and a **pinned, public corpus**. This is the canonical, comprehensive board; the README's
inline tables are excerpts.

![Leaderboard — ×grep (log scale) with ±1σ error bars, fastest at top](leaderboard.png)

- **Task:** `-r -i error` (recursive, case-insensitive, fixed-string) over a 6-repo source tree.
- **Baseline:** GNU grep `-rIiF`, same run, same corpus. `×grep` is the geometric mean of
  `mean(impl) / mean(grep)` over the repos that completed. **`×grep < 1` means *faster than GNU grep*.**
- **±1σ:** the propagated relative uncertainty of `×grep`, from hyperfine's per-measurement standard
  deviation: `(1/n)·√Σ[(σ_impl/μ_impl)² + (σ_grep/μ_grep)²]`. **Where two rows' error bars overlap, the
  ordering between them is not statistically meaningful.** A trailing `~` means at least one (slow) repo
  was a single timed run with no stddev, so the bar understates the true uncertainty there.
- **Corpus (pinned, `tests/corpus.lock`):** camilladsp · jellyfin · navidrome · onyx · immich · jdk
  (size-ordered; jdk is the heavyweight, GNU grep ≈ 859 ms on it).
- **Harness:** `tests/leaderboard.sh`. Fast (impl, repo) pairs get hyperfine precision (10–12 runs); slow
  ones use a single bounded run. Per-(impl, repo) timeout 300 s — a repo that exceeds it is excluded from
  that impl's geomean and marked `slow:<repo>`. Correctness gate: a result counts only if its match-line
  count equals GNU grep's (`LC_ALL=C`, byte-level — see [BENCHMARKING.md](BENCHMARKING.md)).
- **Machine:** i5-8400 (6 cores, AVX2), CPU governor `performance`.
- **Run:** 2026-06-23, 48 impls, total wall-clock 36.6 min. Regenerate the chart with
  `python3 tests/plot_leaderboard.py`.

Every implementation is **byte-exact vs GNU grep on every repo it completes**. Raku and Red reach only
5/6 — they genuinely exceed the 300 s gate on jdk (a speed limit, not a wrong answer). `startup` = mean run
on a single small file (boot-dominated, no scan); `repos` = how many of the 6 passed the correctness gate.

| # | language | variant | ×grep | ±1σ | startup | repos | notes |
|--:|---|---|--:|:--:|--:|:--:|---|
| 1 | **asm** | hand-SIMD | **0.18×** | ±4% | 0.2 ms | 6/6 | |
| 2 | **C** | hand-SIMD | **0.19×** | ±3% | 0.5 ms | 6/6 | |
| 3 | **Zig** | hand-SIMD | **0.21×** | ±3% | 0.4 ms | 6/6 | |
| 4 | **Rust** | idiomatic | **0.39×** | ±1% | 1.0 ms | 6/6 | |
| 5 | **Zig** | idiomatic, MT | **0.50×** | ±1% | 1.7 ms | 6/6 | |
| 6 | **C** | idiomatic, MT | **0.53×** | ±1% | 0.7 ms | 6/6 | |
| 7 | **C++** | tuned, MT | **0.61×** | ±2% | 1.3 ms | 6/6 | |
| 8 | **Go** | goroutines | **0.69×** | ±1% | 1.1 ms | 6/6 | |
| 9 | **LuaJIT** | tuned, MT | **0.87×** | ±1% | 2.1 ms | 6/6 | |
| – | _GNU grep_ | _baseline_ | _1.00×_ | – | – | – | _reference_ |
| 10 | **Fortran** | tuned, MT | 1.13× | ±10% | 1.0 ms | 6/6 | |
| 11 | **GraalVM** | native-image | 1.33× | ±2% | 2.2 ms | 6/6 | AOT-compiled Java |
| 12 | **Common Lisp** | tuned, MT | 1.35× | ±1% | 3.5 ms | 6/6 | SBCL native image |
| 13 | **OCaml** | tuned, MT | 1.39× | ±3% | 1.0 ms | 6/6 | Domains |
| 14 | **Ada** | tuned, MT | 2.23× | ±1% | 0.8 ms | 6/6 | tasks |
| 15 | **Free Pascal** | tuned, MT | 2.35× | ±1% | 1.1 ms | 6/6 | |
| 16 | **Pony** | tuned, MT | 2.58× | ±7% | 5.3 ms | 6/6 | actor model |
| 17 | **Swift** | tuned, MT | 2.60× | ±1% | 2.5 ms | 6/6 | + ARC |
| 18 | **Chapel** | tuned, MT | 2.68× | ±3% | 16.1 ms | 6/6 | HPC `forall` |
| 19 | **D** | tuned, MT | 2.69× | ±2% | 1.0 ms | 6/6 | + GC |
| 20 | **Odin** | tuned, MT | 2.88× | ±1% | 2.7 ms | 6/6 | |
| 21 | **Crystal** | tuned, MT | 3.00× | ±1% | 3.9 ms | 6/6 | + GC |
| 22 | **Nim** | tuned, MT | 3.17× | ±1% | 0.7 ms | 6/6 | compiles to C |
| 23 | **Bun** | tuned, MT | 4.59× | ±2% | 38.3 ms | 6/6 | JS/TS (JavaScriptCore) |
| 24 | **C#** | NativeAOT | 4.90× | ±1% | 1.4 ms | 6/6 | AOT, no JIT/JVM |
| 25 | **Go** | idiomatic, 1-thread | 5.22× | ±3%~ | 1.1 ms | 6/6 | |
| 26 | **Codon** | std | 5.65× | ±2% | 5.8 ms | 6/6 | Python syntax → LLVM AOT |
| 27 | **Python** | tuned, MT | 6.02× | ±1% | 26.7 ms | 6/6 | CPython, multiprocessing |
| 28 | **Perl** | std | 6.07× | ±1%~ | 4.4 ms | 6/6 | C-backed `index` |
| 29 | **Clojure-native** | tuned, MT | 6.43× | ±1%~ | 2.4 ms | 6/6 | GraalVM native-image |
| 30 | **Node.js** | tuned, MT | 6.64× | ±1%~ | 67.7 ms | 6/6 | V8, `worker_threads` |
| 31 | **Haskell** | tuned, MT | 6.71× | ±1%~ | 15.4 ms | 6/6 | GHC + RTS |
| 32 | **Rust → WASI** | std | 7.68× | ±1%~ | 12.1 ms | 6/6 | `wasm32-wasip1` / wasmtime |
| 33 | **Ruby** | std | 7.97× | ±1%~ | 42.7 ms | 6/6 | CRuby, C-backed `String#index` |
| 34 | **J** | std | 8.65× | ±1%~ | 47.7 ms | 6/6 | array lang; `E.` is a C primitive |
| 35 | **Scala-Native** | std | 9.72× | ±1%~ | 1.8 ms | 6/6 | LLVM AOT — no JVM |
| 36 | **Java** | tuned, MT | 10.19× | ±4% | 32.7 ms | 6/6 | JVM — startup-bound |
| 37 | **Dart** | std | 10.58× | ±1%~ | 2.3 ms | 6/6 | native self-contained exe |
| 38 | **PyPy** | std | 11.17× | ±1%~ | 48.3 ms | 6/6 | unchanged CPython src under a tracing JIT |
| 39 | **Kotlin** | tuned, MT | 11.61× | ±3% | 42.0 ms | 6/6 | JVM — startup-bound |
| 40 | **Dyalog APL** | std | 12.82× | ±1%~ | 46.5 ms | 6/6 | C-backed `⍷`; `ENABLE_CEF=0` (no Chromium) |
| 41 | **Deno** | tuned, MT | 21.42× | ±1%~ | 70.7 ms | 6/6 | JS/TS (V8) |
| 42 | **Clojure** | tuned, MT | 23.24× | ±1%~ | 405.5 ms | 6/6 | JVM AOT — startup-bound |
| 43 | **awk** | std | 23.68× | ±1%~ | 2.4 ms | 6/6 | interpreted (gawk) |
| 44 | **Julia** | tuned, MT | 27.66× | ±1%~ | 598.4 ms | 6/6 | JIT — startup + compile tax |
| 45 | **Elixir** | tuned, MT | 34.55× | ±1%~ | 418.0 ms | 6/6 | BEAM — startup-bound |
| 46 | **Bash** | std | 172.48× | ±1%~ | 2.7 ms | 6/6 | pure shell; no concurrency primitive |
| 47 | **Raku** | std | 351.64× | ±1%~ | 422.7 ms | 5/6 | MoarVM — `slow:jdk` (just over 300 s) |
| 48 | **Red** | std | 706.66× | ±1%~ | 17.6 ms | 5/6 | Rebol-family, interpreted — `slow:jdk` |
| – | **Forth** | std | **DNF** | – | 6.0 ms | 0/6 | gforth; interpreted byte-at-a-time scan exceeds the 300 s gate on every repo (excluded from the timed run; the bottom of the board) |

**Variant suffixes:** `std` = idiomatic single-pass; `MT` = +threads; `tuned` = +buffer-reuse / chunking.
A language ships only `std` when its runtime offers no idiomatic shared-memory parallelism (interpreters
launched per-process, array langs) — the *absence* of an MT row is itself a data point.

## How to read it

**Nine implementations beat GNU grep**; top-to-bottom the spread is ~3,900×, and it sorts almost entirely
by **runtime model, not language syntax**:

- **The top trio is a tie.** asm `0.18 ±4%`, C `0.19 ±3%`, Zig `0.21 ±3%` — the error bars overlap, so the
  hand-SIMD natives are statistically indistinguishable. (In isolation the SIMD scan is memory-bandwidth-
  bound and identical across them; what little separates these runs is process-startup jitter, where asm's
  no-libc binary has a slight edge.) Then the idiomatic-tuned native cluster (Rust, C++, Go, LuaJIT).
- **Same scan, opposite placement.** J's `E.` and Dyalog's `⍷` are *both* C primitives (fast scans), yet
  J lands near the natives (#34) while Dyalog (#40) sits lower — sorted apart by interpreter boot. (GNU APL
  was attempted for the array slot but couldn't pass the harness on this machine's broken `gnu-apl 1.9-1`
  build — see [RESULTS.md](RESULTS.md); J and Dyalog represent it.)
- **Startup-bound tail.** The JVM/JIT/BEAM runtimes (Java, Kotlin, Clojure, Julia, Elixir) sit low because
  on a 6-repo tree their boot is a large share of total time; on a *large* tree the scan amortizes their
  boot and they climb sharply.
- **Interpreted floor.** Bash, Raku, Red, and (off the board) Forth scan byte-at-a-time in the interpreter
  — the only tier where the *language* genuinely caps throughput.

`×grep` is corpus-sensitive (it's a ratio to grep on *this* tree), so read the **ordering**, not the
absolute multiplier. Full methodology: [BENCHMARKING.md](BENCHMARKING.md). Raw run log: `leaderboard_final.txt`.
