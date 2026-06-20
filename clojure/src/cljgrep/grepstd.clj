;; cljgrep_std - idiomatic single-threaded Clojure: java.nio Files/readAllBytes
;; + byte-array search via interop (no regex), buffered raw-byte stdout.
;; Mirrors go/grep.go semantics byte-for-byte. Bytes, not Unicode chars.
(ns cljgrep.grepstd
  (:gen-class)
  (:import [java.io BufferedOutputStream OutputStream File FileInputStream]
           [java.nio.charset StandardCharsets]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

;; ASCII-only, length-preserving lowercase (matches grep -iF; not Unicode).
(defn ascii-lower-copy ^"[B" [^bytes src len]
  (let [len (long len)
        dst (byte-array len)]
    (loop [i 0]
      (if (< i len)
        (let [b (aget src i)]
          (aset dst i (if (and (>= b (byte 65)) (<= b (byte 90)))
                        (byte (+ b 32))
                        b))
          (recur (inc i)))
        dst))))

;; index of needle in hay[from:len], or -1. Empty needle returns from.
(defn index-of [^bytes hay len from ^bytes needle]
  (let [len (long len) from (long from)
        n (alength needle)]
    (if (zero? n)
      from
      (let [end (- len n)]
        (loop [i from]
          (if (> i end)
            -1
            (let [match? (loop [j 0]
                           (cond
                             (= j n) true
                             (= (aget hay (+ i j)) (aget needle j)) (recur (inc j))
                             :else false))]
              (if match? i (recur (inc i))))))))))

(defn last-index-nl [^bytes data m]
  (loop [i (dec (long m))]
    (cond (< i 0) -1
          (= (aget data i) (byte 10)) i
          :else (recur (dec i)))))

(defn index-nl [^bytes data from len]
  (let [len (long len)]
    (loop [i (long from)]
      (cond (>= i len) -1
            (= (aget data i) (byte 10)) i
            :else (recur (inc i))))))

(defn search-file
  [^OutputStream out ^bytes pat ^bytes lpat ci multi matched ^String path]
  (let [^"[B" data (try (with-open [in (FileInputStream. path)] (.readAllBytes in))
                        (catch Exception _ nil))]
    (when data
      (let [len (alength data)
            peek (min len 65536)
            ;; binary check on prefix
            binary? (loop [i 0]
                      (cond (>= i peek) false
                            (zero? (aget data i)) true
                            :else (recur (inc i))))]
        (when-not binary?
          (let [hay (if ci (ascii-lower-copy data len) data)
                needle (if ci lpat pat)
                ^"[B" path-bytes (.getBytes path StandardCharsets/ISO_8859_1)]
            (loop [pos 0]
              (when (<= pos len)
                (let [m (index-of hay len pos needle)]
                  ;; m == len is the empty-pattern match at EOF (after the final
                  ;; newline, or an empty file): not a real line, so skip it to
                  ;; match grep -F (which matches each existing line once).
                  (when (and (>= m 0) (< m len))
                    (let [ls (inc (last-index-nl data m))
                          j (index-nl data m len)
                          le (if (>= j 0) j len)]
                      (reset! matched true)
                      (when multi
                        (.write out path-bytes)
                        (.write out (int 58)))
                      (.write out data ls (- le ls))
                      (.write out (int 10))
                      (recur (inc le)))))))))))))

(defn usage []
  (binding [*out* *err*]
    (print "usage: cljgrep [-r] [-i] PATTERN PATH...\n")
    (flush))
  (System/exit 2))

;; java.io-only symlink test (avoids reflective java.nio so it works under GraalVM
;; native-image): canonicalize the parent, re-attach the name, and see if that
;; resolves elsewhere -- isolates the entry from any symlinked ancestor.
(defn symlink? [^File f]
  (let [p (.getParentFile f)
        g (File. ^File (if p (.getCanonicalFile p) f) (.getName f))]
    (not= (.getCanonicalFile g) (.getAbsoluteFile g))))

(defn walk-dir [search-fn ^File dir]
  (when-let [entries (.listFiles dir)]
    (doseq [^File f entries]
      (when-not (symlink? f)
        (cond
          (.isDirectory f) (walk-dir search-fn f)
          (.isFile f) (search-fn (.getPath f)))))))

(defn -main [& args]
  (let [ci (atom false)
        recursive (atom false)
        pat-set (atom false)
        pat (atom nil)
        paths (atom [])
        no-more (atom false)]
    (doseq [^String a args]
      (cond
        (and (not @no-more) (>= (count a) 2) (= (.charAt a 0) \-))
        (if (= a "--")
          (reset! no-more true)
          (doseq [c (subs a 1)]
            (case c
              \i (reset! ci true)
              \r (reset! recursive true)
              (usage))))
        (not @pat-set)
        (do (reset! pat (.getBytes a StandardCharsets/ISO_8859_1))
            (reset! pat-set true))
        :else
        (swap! paths conj a)))
    (when (or (not @pat-set) (empty? @paths))
      (usage))
    (let [^bytes pat @pat
          lpat (ascii-lower-copy pat (alength pat))
          multi (or @recursive (> (count @paths) 1))
          out (BufferedOutputStream. System/out (bit-shift-left 1 16))
          matched (atom false)
          search-fn (fn [path]
                      (search-file out pat lpat @ci multi matched path))]
      (doseq [^String p @paths]
        (let [f (File. p)]
          (cond
            (.isDirectory f) (when @recursive (walk-dir search-fn f))
            (.isFile f) (search-fn p))))
      (.flush out)
      (System/exit (if @matched 0 1)))))
