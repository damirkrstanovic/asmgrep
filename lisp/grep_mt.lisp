;;;; clgrep_std_mt - idiomatic Common Lisp + NAIVE native threads.
;;;; Worker threads pull files from a shared atomic index. Each file gets a
;;;; FRESH full-size octet vector and is read IN FULL before the binary check
;;;; (deliberately allocation-heavy tier). Per-file output serialized.

(declaim (optimize (speed 3) (safety 1) (debug 0)))

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defvar *pat* nil)
(defvar *lpat* nil)
(defvar *ci* nil)
(defvar *recursive* nil)
(defvar *multi* nil)
(defvar *matched* nil)          ; set under *out-mutex*
(defvar *out* nil)
(defvar *out-mutex* (sb-thread:make-mutex :name "out"))

;; shared work queue
(defvar *files* nil)            ; simple-vector of namestrings
(defvar *next* 0)               ; shared index, guarded by *idx-mutex*
(defvar *idx-mutex* (sb-thread:make-mutex :name "idx"))

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

(declaim (ftype (function (octets octets fixnum) (or null fixnum)) byte-search))
(defun byte-search (hay needle start)
  (declare (type octets hay needle) (type fixnum start))
  (let ((hn (length hay)) (nn (length needle)))
    (declare (type fixnum hn nn))
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

(declaim (ftype (function (octets fixnum (unsigned-byte 8)) fixnum) index-byte))
(defun index-byte (data start b)
  (declare (type octets data) (type fixnum start) (type (unsigned-byte 8) b))
  (let ((n (length data)))
    (declare (type fixnum n))
    (loop for i fixnum from start below n
          when (= (aref data i) b) do (return-from index-byte i))
    -1))

(defun path-octets (path)
  (sb-ext:string-to-octets path :external-format :latin-1))

;; NAIVE: fresh full octet vector, whole file read before binary check.
(defun read-whole-file (path)
  (handler-case
      (with-open-file (s path :element-type '(unsigned-byte 8)
                             :if-does-not-exist nil)
        (unless s (return-from read-whole-file nil))
        (let* ((len (file-length s))
               (data (make-array len :element-type '(unsigned-byte 8))))
          (declare (type octets data))
          (let ((got (read-sequence data s)))
            (if (= got len) data (subseq data 0 got)))))
    (error () nil)))

;; Per-file output collector: an adjustable octet vector with fill pointer.
(declaim (inline obuf-byte))
(defun obuf-byte (buf b)
  (declare (type (unsigned-byte 8) b))
  (vector-push-extend b buf))

(defun obuf-seq (buf src start end)
  (declare (type octets src) (type fixnum start end))
  (loop for i fixnum from start below end do
    (vector-push-extend (aref src i) buf)))

;; Search octet data; append output bytes to adjustable octet vector OUT-BUF.
;; Returns T if any match found.
(defun search-data (data path-bytes out-buf)
  (declare (type octets data))
  (let* ((len (length data)) (peek (min len 65536)) (found nil))
    (declare (type fixnum len peek))
    (dotimes (i peek)
      (when (zerop (aref data i)) (return-from search-data nil)))
    (let ((hay data) (needle *pat*))
      (declare (type octets needle))
      (when *ci*
        (setf hay (ascii-lower-copy data))
        (setf needle *lpat*))
      (let ((hay (the octets hay)) (pos 0))
        (declare (type fixnum pos))
        (loop while (< pos len) do
          (let ((m (byte-search hay needle pos)))
            (unless m (return))
            (locally (declare (type fixnum m))
              (let* ((ls (1+ (last-index-byte data m 10)))
                     (ie (index-byte data m 10))
                     (le (if (>= ie 0) ie len)))
                (declare (type fixnum ls le))
                (setf found t)
                (when *multi*
                  (obuf-seq out-buf path-bytes 0 (length path-bytes))
                  (obuf-byte out-buf 58))
                (obuf-seq out-buf data ls le)
                (obuf-byte out-buf 10)
                (setf pos (+ le 1))))))))
    found))

(defun search-file (path)
  "Search PATH, emitting its whole output block atomically under *out-mutex*."
  (let ((data (read-whole-file path)))
    (when data
      (let ((out-buf (make-array 256 :element-type '(unsigned-byte 8)
                                     :fill-pointer 0 :adjustable t)))
        (when (search-data data (when *multi* (path-octets path)) out-buf)
          (sb-thread:with-mutex (*out-mutex*)
            (write-sequence out-buf *out* :end (fill-pointer out-buf))
            (setf *matched* t)))))))

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
  "Push all regular files under DIR (recursive, no symlink follow) onto ACC."
  (dolist (child (list-dir-entries dir) acc)
    (cond ((regular-file-p child) (push child acc))
          ((directory-p child) (setf acc (collect-files child acc)))))
  acc)

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
  "Real CPU count via sysconf(_SC_NPROCESSORS_ONLN); fallback 6."
  (or (ignore-errors
        (let ((n (sb-alien:alien-funcall
                  (sb-alien:extern-alien "sysconf"
                                         (function sb-alien:long sb-alien:int))
                  84)))                 ; _SC_NPROCESSORS_ONLN on Linux
          (when (and (integerp n) (plusp n)) n)))
      6))

(defun worker ()
  (let ((n (length *files*)))
    (declare (type fixnum n))
    (loop
      (let ((i (sb-thread:with-mutex (*idx-mutex*)
                 (prog1 *next* (incf *next*)))))
        (declare (type fixnum i))
        (when (>= i n) (return))
        (search-file (svref *files* i))))))

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
    ;; Build the full work list (expand directories up front).
    (let ((flist '()))
      (dolist (p paths)
        (cond
          ((directory-p p) (when *recursive* (setf flist (collect-files p flist))))
          ((regular-file-p p) (push p flist))
          (t (push p flist))))      ; treat unknown as a file to attempt
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
