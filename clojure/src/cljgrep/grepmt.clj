;; cljgrep_std_mt - idiomatic concurrent Clojure: collect file list, then a
;; fixed thread pool (ExecutorService via interop) over it. Each file gets a
;; FRESH full-size byte[] (Files/readAllBytes) read IN FULL before the binary
;; check (the deliberately allocation-heavy tier). Per-file output collected
;; into a ByteArrayOutputStream and flushed under a lock so files don't
;; interleave.
(ns cljgrep.grepmt
  (:gen-class)
  (:import [java.io BufferedOutputStream ByteArrayOutputStream OutputStream]
           [java.nio.file Files Path Paths LinkOption]
           [java.nio.file.attribute BasicFileAttributes]
           [java.nio.charset StandardCharsets]
           [java.util.stream Stream]
           [java.util ArrayList]
           [java.util.concurrent Executors ExecutorService TimeUnit]
           [java.util.concurrent.atomic AtomicBoolean]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

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

;; returns true if matched; writes output into w. Fresh full read per file.
(defn search-file
  [^ByteArrayOutputStream w ^bytes pat ^bytes lpat ci multi ^String path]
  (let [^"[B" data (try (Files/readAllBytes (Paths/get path (make-array String 0)))
                        (catch Exception _ nil))]
    (if-not data
      false
      (let [len (alength data)
            peek (min len 65536)
            binary? (loop [i 0]
                      (cond (>= i peek) false
                            (zero? (aget data i)) true
                            :else (recur (inc i))))]
        (if binary?
          false
          (let [hay (if ci (ascii-lower-copy data len) data)
                needle (if ci lpat pat)
                path-bytes (.getBytes path StandardCharsets/ISO_8859_1)]
            (loop [pos 0 found false]
              (if (> pos len)
                found
                (let [m (index-of hay len pos needle)]
                  ;; m == len is the empty-pattern match at EOF (not a real
                  ;; line); skip to match grep -F's one-match-per-line.
                  (if (or (< m 0) (>= m len))
                    found
                    (let [ls (inc (last-index-nl data m))
                          j (index-nl data m len)
                          le (if (>= j 0) j len)]
                      (when multi
                        (.write w ^bytes path-bytes)
                        (.write w (int 58)))
                      (.write w data ls (- le ls))
                      (.write w (int 10))
                      (recur (inc le) true))))))))))))

(defn usage []
  (binding [*out* *err*]
    (print "usage: cljgrep [-r] [-i] PATTERN PATH...\n")
    (flush))
  (System/exit 2))

(defn collect [^ArrayList files ^Path dir]
  (with-open [s (Files/walk dir (make-array java.nio.file.FileVisitOption 0))]
    (doseq [^Path p (-> ^Stream s .iterator iterator-seq)]
      (when (Files/isRegularFile p (make-array LinkOption 0))
        (.add files (.toString p))))))

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
          ci @ci
          multi (or @recursive (> (count @paths) 1))
          out (BufferedOutputStream. System/out (bit-shift-left 1 16))
          out-lock (Object.)
          any-match (AtomicBoolean. false)
          files (ArrayList.)]
      (doseq [^String p @paths]
        (let [pp (Paths/get p (make-array String 0))
              attrs (try (Files/readAttributes pp BasicFileAttributes
                                               (make-array LinkOption 0))
                         (catch Exception _ nil))]
          (when attrs
            (if (.isDirectory ^BasicFileAttributes attrs)
              (when @recursive (collect files pp))
              (.add files p)))))
      (let [nthreads (.availableProcessors (Runtime/getRuntime))
            ^ExecutorService pool (Executors/newFixedThreadPool nthreads)
            n (.size files)
            idx (java.util.concurrent.atomic.AtomicInteger. 0)
            task (fn []
                   (let [buf (ByteArrayOutputStream. (bit-shift-left 1 16))]
                     (loop []
                       (let [i (.getAndIncrement idx)]
                         (when (< i n)
                           (.reset buf)
                           (let [^String path (.get files i)]
                             (when (search-file buf pat lpat ci multi path)
                               (.set any-match true))
                             (when (pos? (.size buf))
                               (locking out-lock
                                 (.writeTo buf out))))
                           (recur))))))]
        (let [futures (doall (repeatedly nthreads #(.submit pool ^Runnable task)))]
          (doseq [f futures] (.get f)))
        (.shutdown pool)
        (.awaitTermination pool 1 TimeUnit/MINUTES))
      (.flush out)
      (System/exit (if (.get any-match) 0 1)))))
