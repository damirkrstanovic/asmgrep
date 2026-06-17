;;;; Build clgrep_std_mt. Invoke: sbcl --non-interactive --load lisp/build_mt.lisp
(load (merge-pathnames "grep_mt.lisp" *load-pathname*))
(sb-ext:save-lisp-and-die "bin/clgrep_std_mt"
                          :toplevel #'main
                          :executable t
                          :save-runtime-options t)
