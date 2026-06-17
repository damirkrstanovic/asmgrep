;;;; Build clgrep_std_mt_tuned. Invoke: sbcl --non-interactive --load lisp/build_mt_tuned.lisp
(load (merge-pathnames "grep_mt_tuned.lisp" *load-pathname*))
(sb-ext:save-lisp-and-die "bin/clgrep_std_mt_tuned"
                          :toplevel #'main
                          :executable t
                          :save-runtime-options t)
