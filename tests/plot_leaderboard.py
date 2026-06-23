#!/usr/bin/env python3
"""Render the ×grep leaderboard (with ±1σ error bars) to docs/leaderboard.png.

Parses tests/leaderboard.sh output (default: leaderboard_final.txt) — the ranked
table rows of the form:  <bin>  <x>x  ±<p>%[~]  <startup>ms  <r>/<R>  <secs>s  [notes]
Usage: tests/plot_leaderboard.py [leaderboard_final.txt] [docs/leaderboard.png]
"""
import re, sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

SRC = sys.argv[1] if len(sys.argv) > 1 else "leaderboard_final.txt"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/leaderboard.png"

NAME = {
    "asmgrep": "asm (hand-SIMD)", "cgrep": "C (hand-SIMD)", "zgrep": "Zig (hand-SIMD)",
    "rustgrep": "Rust", "zgrep_std_mt": "Zig (MT)", "cgrep_std_mt": "C (MT)",
    "cppgrep_std_mt_tuned": "C++", "gogrep_mt": "Go (MT)", "ljgrep_std_mt_tuned": "LuaJIT",
    "fortgrep_std_mt_tuned": "Fortran", "graalgrep_std_mt_tuned": "GraalVM (native-image)",
    "clgrep_std_mt_tuned": "Common Lisp", "ocgrep_std_mt_tuned": "OCaml",
    "adagrep_std_mt_tuned": "Ada", "fpgrep_std_mt_tuned": "Free Pascal",
    "ponygrep_std_mt_tuned": "Pony", "swiftgrep_std_mt_tuned": "Swift",
    "chplgrep_std_mt_tuned": "Chapel", "dgrep_std_mt_tuned": "D",
    "odingrep_std_mt_tuned": "Odin", "crgrep_std_mt_tuned": "Crystal",
    "nimgrep_std_mt_tuned": "Nim", "bungrep_std_mt_tuned": "Bun",
    "csgrep_aot_std_mt_tuned": "C# (NativeAOT)", "gogrep": "Go (1 thread)",
    "codongrep_std": "Codon", "pygrep_std_mt_tuned": "Python", "perlgrep_std": "Perl",
    "cljgraalgrep_std_mt_tuned": "Clojure-native", "nodegrep_std_mt_tuned": "Node.js",
    "haskgrep_std_mt_tuned": "Haskell", "wasmgrep_std": "Rust→WASI", "rubygrep_std": "Ruby",
    "ijsgrep_std": "J", "scalagrep_std": "Scala-Native", "jgrep_std_mt_tuned": "Java",
    "dartgrep_std": "Dart", "pypygrep_std": "PyPy", "ktgrep_std_mt_tuned": "Kotlin",
    "dyalogrep_std": "Dyalog APL", "denogrep_std_mt_tuned": "Deno",
    "cljgrep_std_mt_tuned": "Clojure", "awkgrep_std": "awk", "jlgrep_std_mt_tuned": "Julia",
    "exgrep_std_mt_tuned": "Elixir", "bashgrep_std": "Bash", "rakugrep_std": "Raku",
    "redgrep_std": "Red",
}

row = re.compile(r"^(\S+)\s+([\d.]+)x\s+±(\d+)%(~?)\s+\S+ms\s+(\d+)/(\d+)")
rows = []
for line in open(SRC, encoding="utf-8"):
    m = row.match(line)
    if not m:
        continue
    b, x, pct, approx, done, total = m.groups()
    rows.append((b, float(x), float(pct), approx == "~", int(done), int(total)))

rows.sort(key=lambda r: r[1])                      # fastest (lowest ×grep) first
labels, xs, errs, approxs, partial = [], [], [], [], []
for b, x, pct, approx, done, total in rows:
    lab = NAME.get(b) or b
    if done < total:
        lab += f"  ({done}/{total})"
    labels.append(lab)
    xs.append(x); errs.append(x * pct / 100.0); approxs.append(approx); partial.append(done < total)

def color(x):
    if x < 1:   return "#2e8b57"   # beats grep — sea green
    if x < 10:  return "#4682b4"   # steel blue
    if x < 100: return "#e8a33d"   # orange
    return "#c0392b"               # red

n = len(xs)
y = list(range(n))[::-1]           # top of chart = fastest
fig, ax = plt.subplots(figsize=(11, 0.34 * n + 1.6))
ax.barh(y, xs, height=0.62, color=[color(x) for x in xs],
        xerr=errs, error_kw=dict(ecolor="#333", elinewidth=0.9, capsize=2.5))
ax.set_yticks(y); ax.set_yticklabels(labels, fontsize=8)
ax.set_xscale("log")
ax.set_xlim(0.12, 1100)
ax.axvline(1.0, color="#888", ls="--", lw=1)
ax.text(1.0, n + 0.4, " GNU grep = 1.0×", color="#555", fontsize=8, va="bottom")
for yi, x, e, ap in zip(y, xs, errs, approxs):
    tag = f"{x:.2f}×" + ("~" if ap else "")
    ax.text(x + e, yi, "  " + tag, va="center", fontsize=7, color="#222")
ax.set_xlabel("×grep  (geometric mean of mean_impl / mean_grep over the corpus; <1 = faster than grep; log scale)",
              fontsize=9)
ax.set_title("asmgrep leaderboard — 48 implementations vs GNU grep, one harness, pinned 6-repo corpus\n"
             "bars = ×grep (fastest at top), whiskers = ±1σ (propagated from hyperfine stddevs); overlapping whiskers ⇒ tie",
             fontsize=10)
ax.margins(y=0.01)
ax.grid(axis="x", which="both", ls=":", lw=0.4, color="#ccc")
ax.set_axisbelow(True)
legend = [Patch(facecolor="#2e8b57", label="faster than grep (<1×)"),
          Patch(facecolor="#4682b4", label="1–10×"),
          Patch(facecolor="#e8a33d", label="10–100×"),
          Patch(facecolor="#c0392b", label=">100×")]
ax.legend(handles=legend, loc="lower right", fontsize=8, framealpha=0.9)
fig.tight_layout()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
fig.savefig(OUT, dpi=140)
print(f"wrote {OUT}  ({n} implementations)")
