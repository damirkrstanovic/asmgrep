;;;; clgrep_std - idiomatic single-threaded Common Lisp (SBCL).
;;;; Literal-substring grep matching `grep -F` byte-for-byte. Operates on
;;;; (unsigned-byte 8) octet vectors; output via a buffered binary fd-stream.

(declaim (optimize (speed 3) (safety 1) (debug 0)))

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defvar *pat* nil)            ; pattern octets
(defvar *lpat* nil)           ; lowercased pattern octets
(defvar *ci* nil)
(defvar *recursive* nil)
(defvar *multi* nil)
(defvar *matched* nil)
(defvar *out* nil)            ; buffered binary output stream

(declaim (inline ascii-lower-byte))
(defun ascii-lower-byte (b)
  (declare (type (unsigned-byte 8) b))
  (if (<= 65 b 90) (+ b 32) b))

;; ASCII-only, length-preserving lowercase copy (matches grep -iF).
(defun ascii-lower-copy (src)
  (declare (type octets src))
  (let* ((n (length src))
         (dst (make-array n :element-type '(unsigned-byte 8))))
    (declare (type octets dst) (type fixnum n))
    (dotimes (i n dst)
      (setf (aref dst i) (ascii-lower-byte (aref src i))))))

;; Index of needle in hay at/after `start`, or NIL. Manual byte search.
(declaim (ftype (function (octets octets fixnum) (or null fixnum)) byte-search))
(defun byte-search (hay needle start)
  (declare (type octets hay needle) (type fixnum start))
  (let ((hn (length hay))
        (nn (length needle)))
    (declare (type fixnum hn nn))
    (when (zerop nn)
      (return-from byte-search start))
    (let ((last (- hn nn))
          (n0 (aref needle 0)))
      (declare (type fixnum last) (type (unsigned-byte 8) n0))
      (loop for i fixnum from start to last
            when (and (= (aref hay i) n0)
                      (loop for j fixnum from 1 below nn
                            always (= (aref hay (+ i j)) (aref needle j))))
              do (return-from byte-search i))
      nil)))

;; Last index of byte `b` in data[0:end), or -1.
(declaim (ftype (function (octets fixnum (unsigned-byte 8)) fixnum) last-index-byte))
(defun last-index-byte (data end b)
  (declare (type octets data) (type fixnum end) (type (unsigned-byte 8) b))
  (loop for i fixnum from (1- end) downto 0
        when (= (aref data i) b) do (return-from last-index-byte i))
  -1)

;; First index of byte `b` in data[start:), or -1.
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

(defun read-whole-file (path)
  "Read entire file as octet vector, or NIL on error."
  (handler-case
      ;; parse-native-namestring: treat path literally. (pathname/open would read
      ;; [..] as a wildcard pattern -> wild pathname -> open errors -> file silently
      ;; skipped (e.g. Next.js [id] / SvelteKit [[..]] dynamic-route dirs).
      (with-open-file (s (sb-ext:parse-native-namestring path)
                         :element-type '(unsigned-byte 8)
                         :if-does-not-exist nil)
        (unless s (return-from read-whole-file nil))
        (let* ((len (file-length s))
               (data (make-array len :element-type '(unsigned-byte 8))))
          (declare (type octets data))
          (let ((got (read-sequence data s)))
            (if (= got len) data (subseq data 0 got)))))
    (error () nil)))

;; Search octet data and emit matches to *out*. `path-bytes` used when *multi*.
(defun search-data (data path-bytes)
  (declare (type octets data))
  (let* ((len (length data))
         (peek (min len 65536)))
    (declare (type fixnum len peek))
    ;; binary check on prefix
    (dotimes (i peek)
      (when (zerop (aref data i)) (return-from search-data)))
    (let ((hay data) (needle *pat*))
      (declare (type octets needle))
      (when *ci*
        (setf hay (ascii-lower-copy data))
        (setf needle *lpat*))
      (let ((hay (the octets hay))
            (pos 0))
        (declare (type fixnum pos))
        (loop while (< pos len) do
          (let ((m (byte-search hay needle pos)))
            (unless m (return))
            (locally (declare (type fixnum m))
              (let* ((ls (1+ (last-index-byte data m 10)))
                     (ie (index-byte data m 10))
                     (le (if (>= ie 0) ie len)))
                (declare (type fixnum ls le))
                (setf *matched* t)
                (when *multi*
                  (write-sequence path-bytes *out*)
                  (write-byte 58 *out*))
                (write-sequence data *out* :start ls :end le)
                (write-byte 10 *out*)
                (setf pos (+ le 1))))))))))

(defun search-file (path)
  (let ((data (read-whole-file path)))
    (when data
      (search-data data (when *multi* (path-octets path))))))

;; --- directory walking, regular files only, do not follow symlinks ---

;; lstat returns (ok dev ino mode ...); mode is the 4th value.
(defun lstat-mode (namestring)
  "Return st-mode of namestring via lstat (no symlink follow), or NIL."
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
  "Return child namestrings of dir (skip . and ..); NIL on error."
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

(defun walk-dir* (dir fn)
  (dolist (child (list-dir-entries dir))
    (cond ((regular-file-p child) (funcall fn child))
          ((directory-p child) (walk-dir* child fn)))))

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

(defun parse-and-run (args)
  (let ((paths '())
        (pat-set nil)
        (no-more nil))
    (dolist (a args)
      (cond
        ((and (not no-more) (>= (length a) 1) (char= (char a 0) #\-)
              (>= (length a) 2))
         (if (string= a "--")
             (setf no-more t)
             (loop for k from 1 below (length a) do
               (case (char a k)
                 (#\i (setf *ci* t))
                 (#\r (setf *recursive* t))
                 (t (usage))))))
        ((and (not no-more) (string= a "--"))
         (setf no-more t))
        ((not pat-set)
         (setf *pat* (path-octets a) pat-set t))
        (t (push a paths))))
    (setf paths (nreverse paths))
    (when (or (not pat-set) (null paths)) (usage))
    (setf *lpat* (ascii-lower-copy *pat*))
    (setf *multi* (or *recursive* (> (length paths) 1)))
    (setf *out* (sb-sys:make-fd-stream 1 :output t
                                         :element-type '(unsigned-byte 8)
                                         :buffering :full))
    (dolist (p paths)
      (cond
        ((directory-p p)
         (when *recursive* (walk-dir* p #'search-file)))
        ((regular-file-p p)
         (search-file p))
        ;; non-regular non-dir (e.g. missing): try as plain file read anyway
        (t (search-file p))))
    (finish-output *out*)
    (sb-ext:exit :code (if *matched* 0 1))))

(defun main ()
  (parse-and-run (rest sb-ext:*posix-argv*))
  (sb-ext:exit :code 1))
