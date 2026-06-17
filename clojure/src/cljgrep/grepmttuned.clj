;; cljgrep_std_mt_tuned - idiomatic concurrent Clojure with the memory pillar:
;; each WORKER THREAD reuses ONE growable read buffer + one lowercase buffer
;; across files (thread-local, since reuse must be per-thread not per-task).
;; Read only a 64 KB prefix first, NUL-check that prefix, read the rest only if
;; it passed. Per-file output collected into a per-thread ByteArrayOutputStream
;; and flushed under a lock so files don't interleave.
(ns cljgrep.grepmttuned
  (:gen-class)
  (:import [java.io BufferedOutputStream ByteArrayOutputStream InputStream OutputStream]
           [java.nio.file Files Path Paths LinkOption]
           [java.nio.file.attribute BasicFileAttributes]
           [java.nio.charset StandardCharsets]
           [java.util.stream Stream]
           [java.util ArrayList]
           [java.util.concurrent Executors ExecutorService TimeUnit]
           [java.util.concurrent.atomic AtomicBoolean AtomicInteger]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:const PEEK 65536)

;; ASCII-only, length-preserving lowercase into a (reused) dst of >= len.
(defn ascii-lower! [^bytes dst ^bytes src len]
  (let [len (long len)]
    (loop [i 0]
      (when (< i len)
        (let [b (aget src i)]
          (aset dst i (if (and (>= b (byte 65)) (<= b (byte 90)))
                        (byte (+ b 32))
                        b))
          (recur (inc i)))))))

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

;; Read fully into buf[off..off+n); buf must have capacity. Returns true on success.
(defn read-fully? [^InputStream in ^bytes buf ^long off ^long n]
  (loop [got 0]
    (if (>= got n)
      true
      (let [r (.read in buf (int (+ off got)) (int (- n got)))]
        (if (< r 0)
          false
          (recur (+ got r)))))))

;; Worker state: a per-thread mutable holder for the reused read + lowercase
;; buffers. A 2-slot object[] (slot 0 = read buffer, slot 1 = lowercase buffer)
;; — simple, externally mutable (unlike deftype private mutable fields).
(def ^:const RBUF 0)
(def ^:const LOWBUF 1)

(defn ensure-cap ^"[B" [^bytes b ^long need]
  (if (or (nil? b) (< (alength b) need))
    (byte-array need)
    b))

;; returns true if matched; writes output into w. Reuses buffers via `state`.
(defn search-file
  [^ByteArrayOutputStream w ^objects state ^bytes pat ^bytes lpat ci multi ^String path]
  (let [pp (Paths/get path (make-array String 0))
        size (try (Files/size pp) (catch Exception _ -1))]
    (if (< size 0)
      false
      (let [size (long size)
            peek (min size PEEK)]
        (with-open [in (Files/newInputStream pp (make-array java.nio.file.OpenOption 0))]
          ;; ensure read buffer holds at least the prefix
          (aset state RBUF (ensure-cap (aget state RBUF) peek))
          (let [^bytes rbuf0 (aget state RBUF)]
            (if-not (read-fully? in rbuf0 0 peek)
              false
              ;; binary check on prefix
              (let [binary? (loop [i 0]
                              (cond (>= i peek) false
                                    (zero? (aget rbuf0 i)) true
                                    :else (recur (inc i))))]
                (if binary?
                  false  ;; rest left unread (the tuning win)
                  (do
                    ;; grow + read remainder only now that prefix passed
                    (when (> size peek)
                      (let [^bytes old (aget state RBUF)
                            grown (ensure-cap old size)]
                        (when-not (identical? old grown)
                          (System/arraycopy old 0 grown 0 peek))
                        (aset state RBUF grown)))
                    (let [^bytes data (aget state RBUF)]
                      (when (> size peek)
                        (when-not (read-fully? in data peek (- size peek))
                          (throw (ex-info "short read" {}))))
                      (let [len size
                            hay (if ci
                                  (do (aset state LOWBUF
                                            (ensure-cap (aget state LOWBUF) len))
                                      (ascii-lower! (aget state LOWBUF) data len)
                                      (aget state LOWBUF))
                                  data)
                            ^bytes needle (if ci lpat pat)
                            path-bytes (.getBytes path StandardCharsets/ISO_8859_1)]
                        (loop [pos 0 found false]
                          (if (> pos len)
                            found
                            (let [m (index-of hay len pos needle)]
                              ;; m == len is the empty-pattern match at EOF (not
                              ;; a real line); skip to match grep -F.
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
                                  (recur (inc le) true))))))))))))))))))

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
          patlen (alength pat)
          lpat (byte-array patlen)
          _ (ascii-lower! lpat pat patlen)
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
            idx (AtomicInteger. 0)
            task (fn []
                   ;; per-thread reused buffers (slot 0 = read, slot 1 = lower)
                   (let [state (object-array 2)
                         buf (ByteArrayOutputStream. (bit-shift-left 1 16))]
                     (loop []
                       (let [i (.getAndIncrement idx)]
                         (when (< i n)
                           (.reset buf)
                           (let [^String path (.get files i)]
                             (when (try (search-file buf state pat lpat ci multi path)
                                        (catch Exception _ false))
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
