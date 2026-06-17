(defproject cljgrep "1.0.0"
  :description "grep -F clone in idiomatic Clojure (three performance tiers)"
  :dependencies [[org.clojure/clojure "1.12.0"]]
  :source-paths ["src"]
  ;; Each tier is its own AOT'd uberjar so `java -jar` startup is JVM+Clojure
  ;; runtime only (no tooling/dep-resolution cold start).
  ;; Per-profile :target-path so `lein uberjar`'s clean step doesn't clobber
  ;; sibling jars (each tier builds into its own target dir).
  :profiles {:std       {:aot [cljgrep.grepstd]
                         :main cljgrep.grepstd
                         :target-path "target/std"
                         :uberjar-name "cljgrep_std.jar"}
             :mt        {:aot [cljgrep.grepmt]
                         :main cljgrep.grepmt
                         :target-path "target/mt"
                         :uberjar-name "cljgrep_std_mt.jar"}
             :mttuned   {:aot [cljgrep.grepmttuned]
                         :main cljgrep.grepmttuned
                         :target-path "target/mttuned"
                         :uberjar-name "cljgrep_std_mt_tuned.jar"}})
