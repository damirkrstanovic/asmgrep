;;;; clgrep_std_mt_tuned - Common Lisp + native threads + reused per-thread
;;;; buffer + prefix binary-check.
;;;; Each WORKER THREAD reuses ONE growable read buffer (and one lowercase
;;;; buffer) across files (thread-local). Reads a 64 KB prefix first, NUL-checks
;;;; that prefix, reads the rest only if it passed. Per-file output serialized.

(declaim (optimize (speed 3) (safety 1) (debug 0)))

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defvar *pat* nil)
(defvar *lpat* nil)
(defvar *ci* nil)
(defvar *recursive* nil)
(defvar *multi* nil)
(defvar *matched* nil)
(defvar *out* nil)
(defvar *out-mutex* (sb-thread:make-mutex :name "out"))

(defvar *files* nil)
(defvar *next* 0)               ; shared index, guarded by *idx-mutex*
(defvar *idx-mutex* (sb-thread:make-mutex :name "idx"))

(defconstant +peek+ 65536)

;; Per-thread mutable buffer set (one per worker thread, reused across files).
(defstruct (tbuf (:constructor make-tbuf ()))
  (read (make-array +peek+ :element-type '(unsigned-byte 8)) :type octets)
  (low  (make-array +peek+ :element-type '(unsigned-byte 8)) :type octets)
  (out  (make-array 256 :element-type '(unsigned-byte 8) :fill-pointer 0
                        :adjustable t)))

(declaim (inline ascii-lower-byte))
(defun ascii-lower-byte (b)
  (declare (type (unsigned-byte 8) b))
  (if (<= 65 b 90) (+ b 32) b))

(defun ascii-lower-copy (src)
  (declare (type octets src))
  (let* ((n (length src))
         (dst (make-array n :element-type '(unsigned-byte 8))))
    (declare (type octets dst) (type fixnum n))
    (dotimes (i n dst)
      (setf (aref dst i) (ascii-lower-byte (aref src i))))))

;; Lowercase src[0:n] into a reused buffer, growing it if needed; returns buf.
(defun ascii-lower-into (tb src n)
  (declare (type octets src) (type fixnum n))
  (let ((low (tbuf-low tb)))
    (declare (type octets low))
    (when (< (length low) n)
      (setf low (make-array (max n (* 2 (length low)))
                            :element-type '(unsigned-byte 8))
            (tbuf-low tb) low))
    (locally (declare (type octets low))
      (dotimes (i n low)
        (setf (aref low i) (ascii-lower-byte (aref src i)))))))

(declaim (ftype (function (octets octets fixnum fixnum) (or null fixnum)) byte-search))
(defun byte-search (hay needle start hn)
  "Search needle in hay[start:hn]."
  (declare (type octets hay needle) (type fixnum start hn))
  (let ((nn (length needle)))
    (declare (type fixnum nn))
    (when (zerop nn) (return-from byte-search start))
    (let ((last (- hn nn)) (n0 (aref needle 0)))
      (declare (type fixnum last) (type (unsigned-byte 8) n0))
      (loop for i fixnum from start to last
            when (and (= (aref hay i) n0)
                      (loop for j fixnum from 1 below nn
                            always (= (aref hay (+ i j)) (aref needle j))))
              do (return-from byte-search i))
      nil)))

(declaim (ftype (function (octets fixnum (unsigned-byte 8)) fixnum) last-index-byte))
(defun last-index-byte (data end b)
  (declare (type octets data) (type fixnum end) (type (unsigned-byte 8) b))
  (loop for i fixnum from (1- end) downto 0
        when (= (aref data i) b) do (return-from last-index-byte i))
  -1)

(declaim (ftype (function (octets fixnum fixnum (unsigned-byte 8)) fixnum) index-byte))
(defun index-byte (data start len b)
  (declare (type octets data) (type fixnum start len) (type (unsigned-byte 8) b))
  (loop for i fixnum from start below len
        when (= (aref data i) b) do (return-from index-byte i))
  -1)

(defun path-octets (path)
  (sb-ext:string-to-octets path :external-format :latin-1))

(declaim (inline obuf-byte))
(defun obuf-byte (buf b)
  (declare (type (unsigned-byte 8) b))
  (vector-push-extend b buf))

(defun obuf-seq (buf src start end)
  (declare (type octets src) (type fixnum start end))
  (loop for i fixnum from start below end do
    (vector-push-extend (aref src i) buf)))

;; --- directory walking ---

(defun lstat-mode (namestring)
  (multiple-value-bind (ok dev ino mode) (sb-unix:unix-lstat namestring)
    (declare (ignore dev ino))
    (and ok mode)))

(defun regular-file-p (namestring)
  (let ((m (lstat-mode namestring)))
    (and m (= (logand m sb-unix:s-ifmt) sb-unix:s-ifreg))))

(defun directory-p (namestring)
  (let ((m (lstat-mode namestring)))
    (and m (= (logand m sb-unix:s-ifmt) sb-unix:s-ifdir))))

(defun list-dir-entries (dir-namestring)
  (let ((result '())
        (base (if (and (plusp (length dir-namestring))
                       (char= (char dir-namestring (1- (length dir-namestring))) #\/))
                  dir-namestring
                  (concatenate 'string dir-namestring "/"))))
    (handler-case
        (sb-impl::call-with-native-directory-iterator
         (lambda (next)
           (loop for name = (funcall next)
                 while name
                 unless (or (string= name ".") (string= name ".."))
                   do (push (concatenate 'string base name) result)))
         dir-namestring nil)
      (error () nil))
    (nreverse result)))

(defun collect-files (dir acc)
  (dolist (child (list-dir-entries dir) acc)
    (cond ((regular-file-p child) (push child acc))
          ((directory-p child) (setf acc (collect-files child acc)))))
  acc)

;; Search a file using the thread's reused buffers. TB = tbuf.
;; Returns the number of output bytes appended to (tbuf-out tb), 0 if none.
(defun search-file (path tb)
  (let ((out-buf (tbuf-out tb)))
    (setf (fill-pointer out-buf) 0)
    (handler-case
        ;; parse-native-namestring: treat path literally. (pathname/open would read
        ;; [..] as a wildcard pattern -> wild pathname -> open errors -> file silently
        ;; skipped (e.g. Next.js [id] / SvelteKit [[..]] dynamic-route dirs).
        (with-open-file (s (sb-ext:parse-native-namestring path)
                           :element-type '(unsigned-byte 8)
                           :if-does-not-exist nil)
          (unless s (return-from search-file 0))
          (let* ((len (file-length s))
                 (peek (min len +peek+))
                 (rbuf (tbuf-read tb)))
            (declare (type fixnum len peek) (type octets rbuf))
            ;; ensure read buffer holds at least the prefix
            (when (< (length rbuf) peek)
              (setf rbuf (make-array peek :element-type '(unsigned-byte 8))
                    (tbuf-read tb) rbuf))
            ;; read prefix
            (let ((got (read-sequence rbuf s :end peek)))
              (declare (type fixnum got))
              ;; NUL-check the prefix only
              (dotimes (i (min got peek))
                (when (zerop (aref rbuf i)) (return-from search-file 0)))
              ;; read remainder only if prefix passed
              (let ((total got))
                (declare (type fixnum total))
                (when (> len peek)
                  (when (< (length rbuf) len)
                    (let ((nb (make-array (max len (* 2 (length rbuf)))
                                          :element-type '(unsigned-byte 8))))
                      (declare (type octets nb))
                      (replace nb rbuf :end1 got)
                      (setf rbuf nb (tbuf-read tb) nb)))
                  (let ((got2 (read-sequence rbuf s :start peek :end len)))
                    (setf total got2)))
                (let* ((data rbuf)
                       (n total)
                       (hay data)
                       (needle *pat*))
                  (declare (type octets data needle) (type fixnum n))
                  (when *ci*
                    (setf hay (ascii-lower-into tb data n))
                    (setf needle *lpat*))
                  (let ((hay (the octets hay))
                        (pos 0)
                        (path-bytes (when *multi* (path-octets path))))
                    (declare (type fixnum pos))
                    (loop while (< pos n) do
                      (let ((m (byte-search hay needle pos n)))
                        (unless m (return))
                        (locally (declare (type fixnum m))
                          (let* ((ls (1+ (last-index-byte data m 10)))
                                 (ie (index-byte data m n 10))
                                 (le (if (>= ie 0) ie n)))
                            (declare (type fixnum ls le))
                            (when *multi*
                              (obuf-seq out-buf path-bytes 0 (length path-bytes))
                              (obuf-byte out-buf 58))
                            (obuf-seq out-buf data ls le)
                            (obuf-byte out-buf 10)
                            (setf pos (+ le 1))))))))))))
      (error () (setf (fill-pointer out-buf) 0) (return-from search-file 0)))
    (fill-pointer out-buf)))

(defun usage ()
  (let ((msg (sb-ext:string-to-octets
              "usage: clgrep [-r] [-i] PATTERN PATH..."
              :external-format :latin-1))
        (err (sb-sys:make-fd-stream 2 :output t :element-type '(unsigned-byte 8)
                                      :buffering :none)))
    (write-sequence msg err)
    (write-byte 10 err)
    (finish-output err)
    (sb-ext:exit :code 2)))

(defun cpu-count ()
  (or (ignore-errors
        (let ((n (sb-alien:alien-funcall
                  (sb-alien:extern-alien "sysconf"
                                         (function sb-alien:long sb-alien:int))
                  84)))
          (when (and (integerp n) (plusp n)) n)))
      6))

(defun worker ()
  (let ((tb (make-tbuf))
        (n (length *files*)))
    (declare (type fixnum n))
    (loop
      (let ((i (sb-thread:with-mutex (*idx-mutex*)
                 (prog1 *next* (incf *next*)))))
        (declare (type fixnum i))
        (when (>= i n) (return))
        (let ((nbytes (search-file (svref *files* i) tb)))
          (declare (type fixnum nbytes))
          (when (plusp nbytes)
            (let ((out-buf (tbuf-out tb)))
              (sb-thread:with-mutex (*out-mutex*)
                (write-sequence out-buf *out* :end nbytes)
                (setf *matched* t)))))))))

(defun parse-and-run (args)
  (let ((paths '()) (pat-set nil) (no-more nil))
    (dolist (a args)
      (cond
        ((and (not no-more) (>= (length a) 2) (char= (char a 0) #\-))
         (if (string= a "--")
             (setf no-more t)
             (loop for k from 1 below (length a) do
               (case (char a k)
                 (#\i (setf *ci* t))
                 (#\r (setf *recursive* t))
                 (t (usage))))))
        ((and (not no-more) (string= a "--")) (setf no-more t))
        ((not pat-set) (setf *pat* (path-octets a) pat-set t))
        (t (push a paths))))
    (setf paths (nreverse paths))
    (when (or (not pat-set) (null paths)) (usage))
    (setf *lpat* (ascii-lower-copy *pat*))
    (setf *multi* (or *recursive* (> (length paths) 1)))
    (setf *out* (sb-sys:make-fd-stream 1 :output t
                                         :element-type '(unsigned-byte 8)
                                         :buffering :full))
    (let ((flist '()))
      (dolist (p paths)
        (cond
          ((directory-p p) (when *recursive* (setf flist (collect-files p flist))))
          ((regular-file-p p) (push p flist))
          (t (push p flist))))
      (setf *files* (coerce (nreverse flist) 'simple-vector)))
    (setf *next* 0)
    (let* ((nt (min (cpu-count) (max 1 (length *files*))))
           (threads '()))
      (when (plusp (length *files*))
        (dotimes (k nt)
          (push (sb-thread:make-thread #'worker :name "w") threads))
        (dolist (th threads) (sb-thread:join-thread th)))
      (finish-output *out*)
      (sb-ext:exit :code (if *matched* 0 1)))))

(defun main ()
  (parse-and-run (rest sb-ext:*posix-argv*))
  (sb-ext:exit :code 1))
