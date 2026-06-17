;;;; Build clgrep_std. Invoke: sbcl --non-interactive --load lisp/build_std.lisp
(load (merge-pathnames "grep_std.lisp" *load-pathname*))
(sb-ext:save-lisp-and-die "bin/clgrep_std"
                          :toplevel #'main
                          :executable t
                          :save-runtime-options t)
