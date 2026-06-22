# Builds the three implementations of asmgrep into bin/.
#   make        -> asm (default)
#   make all    -> asm + C
#   make c      -> C version (gcc/clang)
#   make zig    -> Zig version (needs `zig`)
BIN := bin

.DEFAULT_GOAL := asm
all: asm c

asm: $(BIN)/asmgrep
$(BIN)/asmgrep: asm/grep.s | $(BIN)
	as --64 -o $(BIN)/grep.o $<
	ld -o $@ $(BIN)/grep.o

c: $(BIN)/cgrep
$(BIN)/cgrep: c/grep.c | $(BIN)
	$(CC) -O2 -pthread -march=native -o $@ $<

zig: $(BIN)/zgrep
$(BIN)/zgrep: zig/grep.zig | $(BIN)
	zig build-exe -O ReleaseFast -femit-bin=$@ $<

# idiomatic / stdlib versions (single-threaded, high-level stdlib)
cstd: $(BIN)/cgrep_std
$(BIN)/cgrep_std: c/grep_std.c | $(BIN)
	$(CC) -O2 -o $@ $<

zigstd: $(BIN)/zgrep_std
$(BIN)/zgrep_std: zig/grep_std.zig | $(BIN)
	zig build-exe -O ReleaseFast -femit-bin=$@ $<

go: $(BIN)/gogrep
$(BIN)/gogrep: go/grep.go go/go.mod | $(BIN)
	cd go && go build -o ../$(BIN)/gogrep .

# multithreaded idiomatic variants + Rust
cstdmt: $(BIN)/cgrep_std_mt
$(BIN)/cgrep_std_mt: c/grep_std_mt.c | $(BIN)
	$(CC) -O2 -pthread -o $@ $<

zigstdmt: $(BIN)/zgrep_std_mt
$(BIN)/zgrep_std_mt: zig/grep_std_mt.zig | $(BIN)
	zig build-exe -O ReleaseFast -femit-bin=$@ $<

gomt: $(BIN)/gogrep_mt
$(BIN)/gogrep_mt: go/mt/main.go go/go.mod | $(BIN)
	cd go && go build -o ../$(BIN)/gogrep_mt ./mt

rust: $(BIN)/rustgrep
$(BIN)/rustgrep: rust/src/main.rs rust/Cargo.toml | $(BIN)
	cd rust && cargo build --release --offline && cp target/release/rustgrep ../$(BIN)/rustgrep

# Odin: native compiler (LLVM) -> native binaries, like C/Zig (no runtime/launcher).
odin: $(BIN)/odingrep_std $(BIN)/odingrep_std_mt $(BIN)/odingrep_std_mt_tuned
$(BIN)/odingrep_std: odin/grep_std.odin | $(BIN)
	odin build odin/grep_std.odin -file -o:speed -out:$@
$(BIN)/odingrep_std_mt: odin/grep_mt.odin | $(BIN)
	odin build odin/grep_mt.odin -file -o:speed -out:$@
$(BIN)/odingrep_std_mt_tuned: odin/grep_mt_tuned.odin | $(BIN)
	odin build odin/grep_mt_tuned.odin -file -o:speed -out:$@

# Haskell: GHC -> native binary, but with a managed runtime (GC + threaded RTS).
# MT variants link -threaded and default to all cores via -with-rtsopts=-N.
# -dynamic: this GHC install ships shared libs only (no static .a archives).
haskell: $(BIN)/haskgrep_std $(BIN)/haskgrep_std_mt $(BIN)/haskgrep_std_mt_tuned
$(BIN)/haskgrep_std: haskell/grep_std.hs | $(BIN)
	ghc -O2 -dynamic -outputdir haskell/build haskell/grep_std.hs -o $@
$(BIN)/haskgrep_std_mt: haskell/grep_mt.hs | $(BIN)
	ghc -O2 -threaded -rtsopts -with-rtsopts=-N -dynamic -outputdir haskell/build haskell/grep_mt.hs -o $@
$(BIN)/haskgrep_std_mt_tuned: haskell/grep_mt_tuned.hs | $(BIN)
	ghc -O2 -threaded -rtsopts -with-rtsopts=-N -dynamic -outputdir haskell/build haskell/grep_mt_tuned.hs -o $@

# OCaml: native ocamlopt via an opam flambda switch (so -O3's inlining is live;
# the stock/system compiler is non-flambda and -O3 would be a no-op there). Build
# with `make ocaml` after `opam switch create flambda ... ocaml-option-flambda`.
# OCaml 5 Domains give real parallelism. ocamlopt drops .cmi/.cmx/.o next to the
# source, so each rule cleans them after linking.
OCAMLOPT := opam exec --switch=flambda -- ocamlopt -O3 -I +unix unix.cmxa
ocaml: $(BIN)/ocgrep_std $(BIN)/ocgrep_std_mt $(BIN)/ocgrep_std_mt_tuned
$(BIN)/ocgrep_std: ocaml/grep_std.ml | $(BIN)
	$(OCAMLOPT) ocaml/grep_std.ml -o $@ && rm -f ocaml/*.cmi ocaml/*.cmx ocaml/*.o
$(BIN)/ocgrep_std_mt: ocaml/grep_mt.ml | $(BIN)
	$(OCAMLOPT) ocaml/grep_mt.ml -o $@ && rm -f ocaml/*.cmi ocaml/*.cmx ocaml/*.o
$(BIN)/ocgrep_std_mt_tuned: ocaml/grep_mt_tuned.ml | $(BIN)
	$(OCAMLOPT) ocaml/grep_mt_tuned.ml -o $@ && rm -f ocaml/*.cmi ocaml/*.cmx ocaml/*.o

# Free Pascal: fpc native binaries (-FU sends unit intermediates to a build dir).
pascal: $(BIN)/fpgrep_std $(BIN)/fpgrep_std_mt $(BIN)/fpgrep_std_mt_tuned
$(BIN)/fpgrep_std: pascal/grep_std.pas | $(BIN)
	fpc -O3 -FU pascal/build -o$@ pascal/grep_std.pas
$(BIN)/fpgrep_std_mt: pascal/grep_mt.pas | $(BIN)
	fpc -O3 -FU pascal/build -o$@ pascal/grep_mt.pas
$(BIN)/fpgrep_std_mt_tuned: pascal/grep_mt_tuned.pas | $(BIN)
	fpc -O3 -FU pascal/build -o$@ pascal/grep_mt_tuned.pas

# Ada: GNAT native (tasks for parallelism, protected objects for mutex/atomic).
ada: $(BIN)/adagrep_std $(BIN)/adagrep_std_mt $(BIN)/adagrep_std_mt_tuned
$(BIN)/adagrep_std: ada/grep_std.adb | $(BIN)
	mkdir -p ada/build && gnatmake -O2 -D ada/build -o $@ ada/grep_std.adb
$(BIN)/adagrep_std_mt: ada/grep_mt.adb | $(BIN)
	mkdir -p ada/build && gnatmake -O2 -D ada/build -o $@ ada/grep_mt.adb
$(BIN)/adagrep_std_mt_tuned: ada/grep_mt_tuned.adb | $(BIN)
	mkdir -p ada/build && gnatmake -O2 -D ada/build -o $@ ada/grep_mt_tuned.adb

# Fortran: gfortran native; -fopenmp for the MT variants; recursive walk via
# iso_c_binding (opendir/readdir/lstat). Each file defines same-named modules
# (posix_walk/grep_core), so each gets its OWN -J dir or a parallel `make`
# would clobber shared .mod files.
fortran: $(BIN)/fortgrep_std $(BIN)/fortgrep_std_mt $(BIN)/fortgrep_std_mt_tuned
$(BIN)/fortgrep_std: fortran/grep_std.f90 | $(BIN)
	mkdir -p fortran/build/std && gfortran -O2 -J fortran/build/std fortran/grep_std.f90 -o $@
$(BIN)/fortgrep_std_mt: fortran/grep_mt.f90 | $(BIN)
	mkdir -p fortran/build/mt && gfortran -O2 -fopenmp -J fortran/build/mt fortran/grep_mt.f90 -o $@
$(BIN)/fortgrep_std_mt_tuned: fortran/grep_mt_tuned.f90 | $(BIN)
	mkdir -p fortran/build/tuned && gfortran -O2 -fopenmp -J fortran/build/tuned fortran/grep_mt_tuned.f90 -o $@

# D: dmd native compiler -> native binaries, like C/Zig/Pascal (GC runtime, but
# no per-process VM startup). Three variants (idiomatic / +threads / +tuned);
# the tuned worker reuses one buffer + prefix-checks like the others.
DMD := dmd -O -release -inline
d: $(BIN)/dgrep_std $(BIN)/dgrep_std_mt $(BIN)/dgrep_std_mt_tuned
$(BIN)/dgrep_std: d/grep_std.d | $(BIN)
	$(DMD) -of=$@ d/grep_std.d && rm -f d/grep_std.o
$(BIN)/dgrep_std_mt: d/grep_mt.d | $(BIN)
	$(DMD) -of=$@ d/grep_mt.d && rm -f d/grep_mt.o
$(BIN)/dgrep_std_mt_tuned: d/grep_mt_tuned.d | $(BIN)
	$(DMD) -of=$@ d/grep_mt_tuned.d && rm -f d/grep_mt_tuned.o

# C++: idiomatic Modern C++23 (g++), the three-variant native cluster like
# Odin/D/Pascal. std::filesystem walk + std::string_view::find scan + std::jthread
# pool; the tuned worker reuses one per-thread buffer + prefix-checks. Heavier
# C++23 idioms on purpose (std::expected/format_to/print/span/ranges) -- NOT
# "better C". MT variants need -pthread for std::jthread/atomic.
CXX ?= g++
CXXFLAGS_CPP := -O2 -std=c++23
cpp: $(BIN)/cppgrep_std $(BIN)/cppgrep_std_mt $(BIN)/cppgrep_std_mt_tuned
$(BIN)/cppgrep_std: cpp/grep_std.cpp | $(BIN)
	$(CXX) $(CXXFLAGS_CPP) -o $@ $<
$(BIN)/cppgrep_std_mt: cpp/grep_mt.cpp | $(BIN)
	$(CXX) $(CXXFLAGS_CPP) -pthread -o $@ $<
$(BIN)/cppgrep_std_mt_tuned: cpp/grep_mt_tuned.cpp | $(BIN)
	$(CXX) $(CXXFLAGS_CPP) -pthread -o $@ $<

# ----------------------------------------------------------------------------
# Scripting / interpreted / JIT-scripting tier. No compile step: launcher scripts
# (into gitignored bin/) exec the interpreter on the source. Variant count is
# whatever each runtime can HONESTLY support -- gawk has no threads (=> _std only),
# CPython's GIL makes _mt multiprocessing, LuaJIT has no threads (=> _mt fork()s a
# worker pool). That asymmetry is itself part of the finding.
# ----------------------------------------------------------------------------

# Python (CPython 3.x, standard GIL build): os.scandir walk + C-backed bytes.find;
# _mt/_mt_tuned use multiprocessing (threads can't parallelize under the GIL).
python: $(BIN)/pygrep_std
$(BIN)/pygrep_std: python/grep_std.py python/grep_mt.py python/grep_mt_tuned.py | $(BIN)
	printf '#!/bin/sh\nexec python3 $(CURDIR)/python/grep_std.py "$$@"\n'      > $(BIN)/pygrep_std
	printf '#!/bin/sh\nexec python3 $(CURDIR)/python/grep_mt.py "$$@"\n'       > $(BIN)/pygrep_std_mt
	printf '#!/bin/sh\nexec python3 $(CURDIR)/python/grep_mt_tuned.py "$$@"\n' > $(BIN)/pygrep_std_mt_tuned
	chmod +x $(BIN)/pygrep_std $(BIN)/pygrep_std_mt $(BIN)/pygrep_std_mt_tuned

# PyPy: the SAME python/grep_std.py source, run under PyPy's tracing JIT instead of
# CPython. No code changes -- the cleanest "same source, different runtime" data
# point in the board (isolates runtime model from language/algorithm).
pypy: $(BIN)/pypygrep_std
$(BIN)/pypygrep_std: python/grep_std.py | $(BIN)
	printf '#!/bin/sh\nexec pypy3 $(CURDIR)/python/grep_std.py "$$@"\n' > $@ && chmod +x $@

# GNU awk: the text-DSL built for exactly this -- index() literal scan + readdir
# walk -- but no threads/no concurrency, so _std only (the missing _mt is a finding).
awk: $(BIN)/awkgrep_std
$(BIN)/awkgrep_std: awk/grep_std.awk | $(BIN)
	printf '#!/bin/sh\nexec gawk -f $(CURDIR)/awk/grep_std.awk -- "$$@"\n' > $(BIN)/awkgrep_std
	chmod +x $(BIN)/awkgrep_std

# LuaJIT (2.1): trace-compiling JIT; FFI POSIX opendir/readdir walk; string.find
# (plain) scan. No threads => _mt variants fork() a worker pool (each child flock()s
# a shared lockfile around its output write -- the cross-process mutexed flush).
lua: $(BIN)/ljgrep_std $(BIN)/ljgrep_std_mt $(BIN)/ljgrep_std_mt_tuned
$(BIN)/ljgrep_std: lua/grep_std.lua lua/grep_core.lua | $(BIN)
	printf '#!/bin/sh\nexec luajit $(CURDIR)/lua/grep_std.lua "$$@"\n'      > $@ && chmod +x $@
$(BIN)/ljgrep_std_mt: lua/grep_mt.lua lua/grep_core.lua | $(BIN)
	printf '#!/bin/sh\nexec luajit $(CURDIR)/lua/grep_mt.lua "$$@"\n'       > $@ && chmod +x $@
$(BIN)/ljgrep_std_mt_tuned: lua/grep_mt_tuned.lua lua/grep_core.lua | $(BIN)
	printf '#!/bin/sh\nexec luajit $(CURDIR)/lua/grep_mt_tuned.lua "$$@"\n' > $@ && chmod +x $@

# JavaScript: ONE .mjs source set run under three JIT runtimes (node / bun / deno).
# worker_threads runs unchanged on all three, so the _mt variants are cross-runtime.
js: js/grep_std.mjs js/grep_mt.mjs js/grep_mt_tuned.mjs js/grep_core.mjs | $(BIN)
	printf '#!/bin/sh\nexec node $(CURDIR)/js/grep_std.mjs "$$@"\n'              > $(BIN)/nodegrep_std
	printf '#!/bin/sh\nexec node $(CURDIR)/js/grep_mt.mjs "$$@"\n'              > $(BIN)/nodegrep_std_mt
	printf '#!/bin/sh\nexec node $(CURDIR)/js/grep_mt_tuned.mjs "$$@"\n'        > $(BIN)/nodegrep_std_mt_tuned
	printf '#!/bin/sh\nexec bun $(CURDIR)/js/grep_std.mjs "$$@"\n'               > $(BIN)/bungrep_std
	printf '#!/bin/sh\nexec bun $(CURDIR)/js/grep_mt.mjs "$$@"\n'               > $(BIN)/bungrep_std_mt
	printf '#!/bin/sh\nexec bun $(CURDIR)/js/grep_mt_tuned.mjs "$$@"\n'         > $(BIN)/bungrep_std_mt_tuned
	printf '#!/bin/sh\nexec deno run -A $(CURDIR)/js/grep_std.mjs "$$@"\n'       > $(BIN)/denogrep_std
	printf '#!/bin/sh\nexec deno run -A $(CURDIR)/js/grep_mt.mjs "$$@"\n'       > $(BIN)/denogrep_std_mt
	printf '#!/bin/sh\nexec deno run -A $(CURDIR)/js/grep_mt_tuned.mjs "$$@"\n' > $(BIN)/denogrep_std_mt_tuned
	chmod +x $(BIN)/nodegrep_std $(BIN)/nodegrep_std_mt $(BIN)/nodegrep_std_mt_tuned \
	         $(BIN)/bungrep_std  $(BIN)/bungrep_std_mt  $(BIN)/bungrep_std_mt_tuned \
	         $(BIN)/denogrep_std $(BIN)/denogrep_std_mt $(BIN)/denogrep_std_mt_tuned

# Perl 5: idiomatic single-threaded -- recursive readdir walk + C-backed index()
# literal scan + tr/// ASCII case-fold. _std only for now (Perl has cheap fork()
# like LuaJIT; an _mt fork-pool variant is the natural follow-up).
perl: $(BIN)/perlgrep_std
$(BIN)/perlgrep_std: perl/grep_std.pl | $(BIN)
	printf '#!/bin/sh\nexec perl $(CURDIR)/perl/grep_std.pl "$$@"\n' > $@ && chmod +x $@

# Ruby (CRuby): idiomatic single-threaded -- ASCII-8BIT binread + C-backed
# String#index scan + tr case-fold. Completes the Ruby->Crystal arc (same source
# family, opposite runtime). _std only for now (fork()-pool _mt is the follow-up,
# mirroring the Python finding).
ruby: $(BIN)/rubygrep_std
$(BIN)/rubygrep_std: ruby/grep_std.rb | $(BIN)
	printf '#!/bin/sh\nexec ruby $(CURDIR)/ruby/grep_std.rb "$$@"\n' > $@ && chmod +x $@

# Bash: the pure-shell floor -- line-at-a-time read + [[ == *pat* ]] glob test +
# ${,,} case-fold + read -d '' NUL detect. No concurrency primitive at all (like
# gawk), so _std only -- and that's the finding. Expected bottom-of-board.
bash: $(BIN)/bashgrep_std
$(BIN)/bashgrep_std: bash/grep_std.sh | $(BIN)
	printf '#!/bin/sh\nexec bash $(CURDIR)/bash/grep_std.sh "$$@"\n' > $@ && chmod +x $@

# Raku (Rakudo / MoarVM): Perl's successor on a bytecode VM. Whole-file slurp(:bin)
# -> Buf, latin-1 round-trip for 1-char-per-byte, .trans case-fold. The MoarVM
# startup tax dominates a short-lived process (sorts like Julia/JVM cold-start),
# which is the finding -- not the language. _std only.
raku: $(BIN)/rakugrep_std
$(BIN)/rakugrep_std: raku/grep_std.raku | $(BIN)
	printf '#!/bin/sh\nexec raku $(CURDIR)/raku/grep_std.raku "$$@"\n' > $@ && chmod +x $@

# Forth (gforth 0.7.3): the interpreted stack-language floor -- whole-file read +
# hand-written byte-at-a-time substring scan (no library search, no SIMD), open-dir
# walk. No concurrency primitive (like awk/bash), so _std only -- that's the finding.
# Symlinks not skipped in the walk (gforth has no portable lstat); fixtures have none.
forth: $(BIN)/forthgrep_std
$(BIN)/forthgrep_std: forth/grep_std.fs | $(BIN)
	printf '#!/bin/sh\nexec gforth $(CURDIR)/forth/grep_std.fs "$$@"\n' > $@ && chmod +x $@

scripting: python pypy awk lua js perl ruby raku bash forth

# ----------------------------------------------------------------------------
# AOT-compiled / VM / array-language outliers. Each adds a distinct runtime model:
# Dart (native exe), Codon (Python-syntax -> native, the "loop-closer" for python),
# Scala-Native (LLVM AOT off the JVM), Rust->WASI (sandboxed wasm under wasmtime),
# and J (array-language interpreter). All _std only.
# ----------------------------------------------------------------------------

# Dart -> native self-contained exe (dart:io, Uint8List byte scan).
dart: $(BIN)/dartgrep_std
$(BIN)/dartgrep_std: dart/grep_std.dart | $(BIN)
	dart compile exe $(CURDIR)/dart/grep_std.dart -o $@

# Codon: Python *syntax* AOT-compiled to a native binary (LLVM). Same shape as
# python/grep_std.py but str-is-bytes + libc FFI for stat/dirent. The native
# "loop-closer" for the CPython/PyPy rows -- isolates runtime from syntax.
codon: $(BIN)/codongrep_std
$(BIN)/codongrep_std: codon/grep_std.py | $(BIN)
	codon build --release --exe -o $@ $(CURDIR)/codon/grep_std.py

# Scala-Native: the SAME Scala you'd run on the JVM, AOT-compiled via LLVM (no JVM,
# no startup tax). //> using directives in the source select native + release-fast.
# Pairs against a JVM Scala the way GraalVM-native pairs against JVM Java.
scala-native: $(BIN)/scalagrep_std
$(BIN)/scalagrep_std: scala-native/grep_std.scala | $(BIN)
	scala-cli --power package --native $(CURDIR)/scala-native/grep_std.scala -o $@ -f
	rm -rf $(CURDIR)/scala-native/.scala-build

# Rust -> wasm32-wasip1, run under wasmtime. WASI is capability-sandboxed, so the
# launcher preopens host root (--dir /::/) for the guest's std::fs. Measures the
# wasm sandbox tax on otherwise-native Rust.
wasm: $(BIN)/wasmgrep_std
$(BIN)/wasmgrep_std: wasm/grep_std.rs | $(BIN)
	rustc --edition 2021 --target wasm32-wasip1 -O -o $(CURDIR)/wasm/grep_std.wasm $(CURDIR)/wasm/grep_std.rs
	printf '#!/bin/sh\nexec wasmtime run --dir /::/ $(CURDIR)/wasm/grep_std.wasm -- "$$@"\n' > $@ && chmod +x $@

# J (jsoftware): array language. needle E. haystack literal scan, 1!:1 whole-file
# read, recursive 1!:0 walk. Interpreter launched via jconsole; binary is named
# ijsgrep_std (J source ext .ijs) to avoid colliding with Java's jgrep_std.
j: $(BIN)/ijsgrep_std
$(BIN)/ijsgrep_std: j/grep_std.ijs | $(BIN)
	printf '#!/bin/sh\nexec /home/damirk/j9.7/bin/jconsole $(CURDIR)/j/grep_std.ijs "$$@" </dev/null\n' > $@ && chmod +x $@

# Dyalog APL (dyalogscript): the canonical APL, and a STABLE one -- unlike the
# machine's broken gnu-apl build (GNU APL attempted+abandoned, see RESULTS.md). Native ⍷
# (Find) is C-backed (fast scan, like J's E.), but ~313 ms interpreter boot makes
# it startup-bound (Raku/Julia class). Byte-exact via ⎕NREAD/⎕NAPPEND type 80 +
# ⎕UCS. dyalogscript stdout is a non-seekable pipe, so the launcher injects a temp
# file the script writes into, then cats it (exit code via ⎕OFF). _std only.
dyalog: $(BIN)/dyalogrep_std
$(BIN)/dyalogrep_std: dyalog/grep_std.apls | $(BIN)
	printf '#!/bin/sh\nout="$$(mktemp)"\ndyalogscript $(CURDIR)/dyalog/grep_std.apls "$$out" "$$@" 2>/dev/null\nrc=$$?\ncat "$$out"\nrm -f "$$out"\nexit "$$rc"\n' > $@ && chmod +x $@

# ----------------------------------------------------------------------------
# Hosted / JVM languages: compile to bytecode, run via `java`. A tiny launcher
# script is (re)generated into bin/ (which is git-ignored) by each rule.
# These add a new axis to the experiment: JVM startup + JIT warmup on a
# short-lived process. Three variants each (idiomatic / +threads / +tuned).
# ----------------------------------------------------------------------------

# Java (JDK) -> plain .class + `java -cp`
java: $(BIN)/jgrep_std
$(BIN)/jgrep_std: java/GrepStd.java java/GrepMt.java java/GrepMtTuned.java | $(BIN)
	javac -d java $^
	printf '#!/bin/sh\nexec java -cp $(CURDIR)/java GrepStd "$$@"\n'      > $(BIN)/jgrep_std
	printf '#!/bin/sh\nexec java -cp $(CURDIR)/java GrepMt "$$@"\n'       > $(BIN)/jgrep_std_mt
	printf '#!/bin/sh\nexec java -cp $(CURDIR)/java GrepMtTuned "$$@"\n'  > $(BIN)/jgrep_std_mt_tuned
	chmod +x $(BIN)/jgrep_std $(BIN)/jgrep_std_mt $(BIN)/jgrep_std_mt_tuned

# Kotlin -> -include-runtime fat jar + bare `java -jar`. NOTE: launched with the
# SAME bare `java` as the Java and Clojure targets — no per-language -XX tuning —
# so the three JVM rows are measured under identical runtime conditions (fairness).
KTJAVA := java -jar
kotlin: $(BIN)/ktgrep_std
$(BIN)/ktgrep_std: kotlin/grep_std.kt kotlin/grep_mt.kt kotlin/grep_mt_tuned.kt | $(BIN)
	kotlinc kotlin/grep_std.kt      -include-runtime -d kotlin/grep_std.jar
	kotlinc kotlin/grep_mt.kt       -include-runtime -d kotlin/grep_mt.jar
	kotlinc kotlin/grep_mt_tuned.kt -include-runtime -d kotlin/grep_mt_tuned.jar
	printf '#!/bin/sh\nexec $(KTJAVA) $(CURDIR)/kotlin/grep_std.jar "$$@"\n'      > $(BIN)/ktgrep_std
	printf '#!/bin/sh\nexec $(KTJAVA) $(CURDIR)/kotlin/grep_mt.jar "$$@"\n'       > $(BIN)/ktgrep_std_mt
	printf '#!/bin/sh\nexec $(KTJAVA) $(CURDIR)/kotlin/grep_mt_tuned.jar "$$@"\n' > $(BIN)/ktgrep_std_mt_tuned
	chmod +x $(BIN)/ktgrep_std $(BIN)/ktgrep_std_mt $(BIN)/ktgrep_std_mt_tuned

# Clojure -> AOT'd uberjars via Leiningen (offline) + `java -jar`
clojure: $(BIN)/cljgrep_std
$(BIN)/cljgrep_std: clojure/src/cljgrep/grepstd.clj clojure/src/cljgrep/grepmt.clj clojure/src/cljgrep/grepmttuned.clj clojure/project.clj | $(BIN)
	cd clojure && lein with-profile std uberjar && lein with-profile mt uberjar && lein with-profile mttuned uberjar
	printf '#!/bin/sh\nexec java -jar $(CURDIR)/clojure/target/cljgrep_std.jar "$$@"\n'          > $(BIN)/cljgrep_std
	printf '#!/bin/sh\nexec java -jar $(CURDIR)/clojure/target/cljgrep_std_mt.jar "$$@"\n'       > $(BIN)/cljgrep_std_mt
	printf '#!/bin/sh\nexec java -jar $(CURDIR)/clojure/target/cljgrep_std_mt_tuned.jar "$$@"\n' > $(BIN)/cljgrep_std_mt_tuned
	chmod +x $(BIN)/cljgrep_std $(BIN)/cljgrep_std_mt $(BIN)/cljgrep_std_mt_tuned

# GraalVM native-image of the SAME Clojure uberjars -- the "Clojure loop-closer".
# Clojure is the worst startup case in the repo (~0.45 s JVM runtime-init);
# AOT-compiling the identical uberjar bytecode to a native ELF drops it into the
# native cluster. Two requirements made it work: (1) graal-build-time's
# InitClojureClasses feature (the standard Clojure-on-native-image enabler --
# bare --initialize-at-build-time freezes Clojure's *out*/runtime state), fetched
# into clojure/build/; (2) the Clojure sources read via plain java.io, not
# reflective java.nio, so --no-fallback links with no reflection config. Needs the
# clojure: uberjars and GraalVM's native-image (GRAALVM_HOME).
GBT_VER := 1.0.6
GBT := clojure/build/graal-build-time-$(GBT_VER).jar
# `=` (deferred) not `:=`: GRAALVM_HOME is defined further down, so expand at use time.
NI_CLJ = $(GRAALVM_HOME)/bin/native-image --no-fallback -march=native --features=clj_easy.graal_build_time.InitClojureClasses
$(GBT):
	mkdir -p clojure/build && curl -fsSL -o $@ https://repo.clojars.org/com/github/clj-easy/graal-build-time/$(GBT_VER)/graal-build-time-$(GBT_VER).jar
clojure-native: $(BIN)/cljgrep_std $(GBT) | $(BIN)
	$(NI_CLJ) -cp "clojure/target/cljgrep_std.jar:$(GBT)"          cljgrep.grepstd     -o $(BIN)/cljgraalgrep_std
	$(NI_CLJ) -cp "clojure/target/cljgrep_std_mt.jar:$(GBT)"       cljgrep.grepmt      -o $(BIN)/cljgraalgrep_std_mt
	$(NI_CLJ) -cp "clojure/target/cljgrep_std_mt_tuned.jar:$(GBT)" cljgrep.grepmttuned -o $(BIN)/cljgraalgrep_std_mt_tuned

jvm: java kotlin clojure

# GraalVM native-image: AOT-compile the EXISTING java/*.java (UNCHANGED) into a
# native ELF -- the loop-closer on "is the JVM tax the language or the runtime?".
# Same bytecode that runs ~30-40 ms-startup under `java` becomes a sub-ms native
# binary. native-image ships inside the GraalVM JDK but isn't on PATH; point
# GRAALVM_HOME at it (override on the make line if yours differs).
GRAALVM_HOME ?= /usr/lib/jvm/java-25-graalvm-ce
NI := $(GRAALVM_HOME)/bin/native-image --no-fallback -march=native
graalvm: $(BIN)/graalgrep_std $(BIN)/graalgrep_std_mt $(BIN)/graalgrep_std_mt_tuned
java/graal_classes/GrepStd.class: java/GrepStd.java java/GrepMt.java java/GrepMtTuned.java
	mkdir -p java/graal_classes && $(GRAALVM_HOME)/bin/javac -d java/graal_classes $^
$(BIN)/graalgrep_std: java/graal_classes/GrepStd.class | $(BIN)
	$(NI) -cp java/graal_classes GrepStd     -o $@
$(BIN)/graalgrep_std_mt: java/graal_classes/GrepStd.class | $(BIN)
	$(NI) -cp java/graal_classes GrepMt      -o $@
$(BIN)/graalgrep_std_mt_tuned: java/graal_classes/GrepStd.class | $(BIN)
	$(NI) -cp java/graal_classes GrepMtTuned -o $@

# Crystal: Ruby-like syntax, LLVM-compiled to a native binary with a GC. _std is
# single-threaded fibers; the _mt variants need -Dpreview_mt to run fibers on real
# OS threads, and the thread count is read from CRYSTAL_WORKERS at *runtime* -- so
# the mt binaries are wrapped in a launcher that sets it (else they run 1-threaded).
crystal: $(BIN)/crgrep_std $(BIN)/crgrep_std_mt $(BIN)/crgrep_std_mt_tuned
$(BIN)/crgrep_std: crystal/grep_std.cr | $(BIN)
	crystal build --release -o $@ $<
$(BIN)/crgrep_std_mt: crystal/grep_mt.cr | $(BIN)
	crystal build --release -Dpreview_mt -o $@.bin $<
	printf '#!/bin/sh\nexec env CRYSTAL_WORKERS="$${CRYSTAL_WORKERS:-$$(nproc)}" $(CURDIR)/$@.bin "$$@"\n' > $@ && chmod +x $@
$(BIN)/crgrep_std_mt_tuned: crystal/grep_mt_tuned.cr | $(BIN)
	crystal build --release -Dpreview_mt -o $@.bin $<
	printf '#!/bin/sh\nexec env CRYSTAL_WORKERS="$${CRYSTAL_WORKERS:-$$(nproc)}" $(CURDIR)/$@.bin "$$@"\n' > $@ && chmod +x $@

# Elixir (BEAM/Erlang VM): the exotic runtime. :binary.match/2 (C BIF) literal scan
# + File walk; _mt/_mt_tuned spread files across schedulers via Task.async_stream.
# Launchers exec `elixir script.exs` (the BEAM boots fresh each run -- ~480 ms tax).
elixir: $(BIN)/exgrep_std
$(BIN)/exgrep_std: elixir/grep_std.exs elixir/grep_mt.exs elixir/grep_mt_tuned.exs | $(BIN)
	printf '#!/bin/sh\nexec elixir $(CURDIR)/elixir/grep_std.exs -- "$$@"\n'      > $(BIN)/exgrep_std
	printf '#!/bin/sh\nexec elixir $(CURDIR)/elixir/grep_mt.exs -- "$$@"\n'       > $(BIN)/exgrep_std_mt
	printf '#!/bin/sh\nexec elixir $(CURDIR)/elixir/grep_mt_tuned.exs -- "$$@"\n' > $(BIN)/exgrep_std_mt_tuned
	chmod +x $(BIN)/exgrep_std $(BIN)/exgrep_std_mt $(BIN)/exgrep_std_mt_tuned

# Swift: swiftc -O -> native LLVM binary, but with ARC (a THIRD memory model --
# neither tracing-GC nor manual malloc/free). Startup is a hair above the C/D
# cluster because the Swift runtime (libswiftCore/libdispatch) is shared-lib-linked.
# memmem() literal scan via Glibc; _mt = GCD concurrentPerform, _mt_tuned = pthread
# pool (each worker needs a stable identity to own its reused scratch buffer).
swift: $(BIN)/swiftgrep_std $(BIN)/swiftgrep_std_mt $(BIN)/swiftgrep_std_mt_tuned
$(BIN)/swiftgrep_std: swift/grep_std.swift | $(BIN)
	swiftc -O -o $@ $<
$(BIN)/swiftgrep_std_mt: swift/grep_mt.swift | $(BIN)
	swiftc -O -o $@ $<
$(BIN)/swiftgrep_std_mt_tuned: swift/grep_mt_tuned.swift | $(BIN)
	swiftc -O -o $@ $<

# Red (red-lang.org): the Rebol-family homoiconic language -- the gnarliest entry.
# An interpreted, 32-bit i386, single-threaded toolchain with no concurrency story,
# so like gawk it ships _std only. The launcher redirects stdin from /dev/null
# (Red drops to a hanging REPL on a script error otherwise); the script parses
# /proc/self/cmdline itself because Red's system/options/args mis-splits args.
red: $(BIN)/redgrep_std
$(BIN)/redgrep_std: red/grep_std.red | $(BIN)
	printf '#!/bin/sh\nexec red $(CURDIR)/red/grep_std.red "$$@" </dev/null\n' > $@
	chmod +x $@

# Pony (ponylang.io): native LLVM, the marquee CONCURRENCY-SAFETY entry -- an
# actor-model, data-race-free-BY-COMPILE-TIME-DESIGN language (reference
# capabilities), per-actor heaps, lock-free work-stealing scheduler. ponyc
# compiles a DIRECTORY of .pony files into one binary. _std scans serially in
# Main; _mt fans the file list across one Worker actor per scheduler -> one Writer
# (contents shared as immutable `val`); the _mt_tuned worker OWNS+REUSES one
# `Array[U8] ref` buffer in its per-actor heap (libc FFI read + 64KB-prefix check),
# copying matched lines out as fresh `val`. Defaults to all cores (--ponymaxthreads=N).
PONYC ?= $(HOME)/.local/share/ponyup/bin/ponyc
pony: $(BIN)/ponygrep_std $(BIN)/ponygrep_std_mt $(BIN)/ponygrep_std_mt_tuned
$(BIN)/ponygrep_std: pony/std/main.pony | $(BIN)
	$(PONYC) -b ponygrep_std -o $(BIN) pony/std
$(BIN)/ponygrep_std_mt: pony/mt/main.pony | $(BIN)
	$(PONYC) -b ponygrep_std_mt -o $(BIN) pony/mt
$(BIN)/ponygrep_std_mt_tuned: pony/tuned/main.pony | $(BIN)
	$(PONYC) -b ponygrep_std_mt_tuned -o $(BIN) pony/tuned

# Nim (compiles through C to a native ELF): advertises performance + concurrency.
# Idiomatic raw Thread/createThread over a shared Atomic[int] work index (mirrors
# the C/D/Zig pools); mutable seq[byte] => buffer reuse works. Native cluster
# (~0.7 ms startup), but the hand-rolled scalar scan (no stdlib memmem) is the
# bottleneck, so it's scan-bound like Ada/OCaml/Pascal. --threads:on (default in 2.x).
nim: $(BIN)/nimgrep_std $(BIN)/nimgrep_std_mt $(BIN)/nimgrep_std_mt_tuned
$(BIN)/nimgrep_std: nim/grep_std.nim | $(BIN)
	nim c -d:release --threads:on -o:$@ nim/grep_std.nim
$(BIN)/nimgrep_std_mt: nim/grep_mt.nim | $(BIN)
	nim c -d:release --threads:on -o:$@ nim/grep_mt.nim
$(BIN)/nimgrep_std_mt_tuned: nim/grep_mt_tuned.nim | $(BIN)
	nim c -d:release --threads:on -o:$@ nim/grep_mt_tuned.nim

# Julia (1.x JIT): launcher scripts exec `julia` on the source (no compile step).
# Two axes: Threads.@threads shared-memory parallelism over mutable Vector{UInt8}
# (=> the buffer-reuse pillar works) AND Julia's startup + first-call JIT-compile
# latency on a short-lived process (which dominates). _mt/_mt_tuned pass `-t auto`.
julia: $(BIN)/jlgrep_std
$(BIN)/jlgrep_std: julia/grep_std.jl julia/grep_mt.jl julia/grep_mt_tuned.jl julia/grep_core.jl | $(BIN)
	printf '#!/bin/sh\nexec julia --startup-file=no $(CURDIR)/julia/grep_std.jl "$$@"\n'               > $(BIN)/jlgrep_std
	printf '#!/bin/sh\nexec julia --startup-file=no -t auto $(CURDIR)/julia/grep_mt.jl "$$@"\n'        > $(BIN)/jlgrep_std_mt
	printf '#!/bin/sh\nexec julia --startup-file=no -t auto $(CURDIR)/julia/grep_mt_tuned.jl "$$@"\n'  > $(BIN)/jlgrep_std_mt_tuned
	chmod +x $(BIN)/jlgrep_std $(BIN)/jlgrep_std_mt $(BIN)/jlgrep_std_mt_tuned

# Chapel (chpl, native LLVM + qthreads runtime): the HPC parallelism-FIRST entry.
# `forall` makes the data-parallel-for a language primitive; `with (var ...)` task
# intents hand each task its own reused buffer (the buffer-reuse pillar as one
# keyword). Both map cleanly -- but a scalar stdlib bytes.find (no memmem) and a
# ~28 ms qthreads-runtime startup keep it mid-pack. --fast = optimized release.
CHPL ?= chpl
chapel: $(BIN)/chplgrep_std $(BIN)/chplgrep_std_mt $(BIN)/chplgrep_std_mt_tuned
$(BIN)/chplgrep_std: chapel/grep_std.chpl | $(BIN)
	$(CHPL) --fast -o $@ $<
$(BIN)/chplgrep_std_mt: chapel/grep_mt.chpl | $(BIN)
	$(CHPL) --fast -o $@ $<
$(BIN)/chplgrep_std_mt_tuned: chapel/grep_mt_tuned.chpl | $(BIN)
	$(CHPL) --fast -o $@ $<

# Common Lisp (SBCL): save-lisp-and-die -> standalone native executables
# (~4 ms startup; full runtime embedded, so binaries are large).
lisp: $(BIN)/clgrep_std $(BIN)/clgrep_std_mt $(BIN)/clgrep_std_mt_tuned
$(BIN)/clgrep_std: lisp/grep_std.lisp lisp/build_std.lisp | $(BIN)
	sbcl --non-interactive --load lisp/build_std.lisp
$(BIN)/clgrep_std_mt: lisp/grep_mt.lisp lisp/build_mt.lisp | $(BIN)
	sbcl --non-interactive --load lisp/build_mt.lisp
$(BIN)/clgrep_std_mt_tuned: lisp/grep_mt_tuned.lisp lisp/build_mt_tuned.lisp | $(BIN)
	sbcl --non-interactive --load lisp/build_mt_tuned.lisp

# C# NativeAOT (modern .NET): `dotnet publish -p:PublishAot` -> a true
# native ELF (no VM, ~1.6 ms startup), RyuJIT-quality AOT codegen + the vectorized
# `ReadOnlySpan<byte>.IndexOf` SIMD scan. One shared project; StartupObject picks
# the variant. Needs `dotnet` (dotnet-sdk) + clang/lld for the AOT linker.
DOTNET := DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet
AOTPUB := publish csharp/aot/grep.csproj -c Release -r linux-x64 --nologo
csharp-aot: $(BIN)/csgrep_aot_std
$(BIN)/csgrep_aot_std: csharp/aot/Common.cs csharp/aot/GrepStd.cs csharp/aot/GrepMt.cs csharp/aot/GrepMtTuned.cs csharp/aot/grep.csproj | $(BIN)
	$(DOTNET) $(AOTPUB) -p:StartupObject=GrepStd     -o csharp/aot/out_std      && cp csharp/aot/out_std/grep      $(BIN)/csgrep_aot_std
	$(DOTNET) $(AOTPUB) -p:StartupObject=GrepMt       -o csharp/aot/out_mt       && cp csharp/aot/out_mt/grep       $(BIN)/csgrep_aot_std_mt
	$(DOTNET) $(AOTPUB) -p:StartupObject=GrepMtTuned  -o csharp/aot/out_mt_tuned && cp csharp/aot/out_mt_tuned/grep $(BIN)/csgrep_aot_std_mt_tuned

$(BIN):
	mkdir -p $(BIN)

test: asm
	./tests/run.sh
bench: all
	./tests/bench.sh
compare: all
	./tests/compare.sh

clean:
	rm -rf $(BIN)
	rm -rf scala-native/.scala-build wasm/grep_std.wasm

.PHONY: all asm c zig test bench compare clean java kotlin clojure jvm odin lisp haskell ocaml pascal ada fortran d csharp-aot cpp python awk lua js scripting graalvm crystal elixir swift red pony nim julia chapel clojure-native perl ruby bash pypy raku forth dart codon scala-native wasm j dyalog
