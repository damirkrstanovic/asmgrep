#!/usr/bin/env bash
# bashgrep_std - the pure-shell floor. Recursive glob walk + line-at-a-time
# `read` + `[[ == *"$needle"* ]]` literal glob test + `${,,}` ASCII case-fold +
# `read -d ''` NUL detection for the binary skip. No external tools in the hot
# path (no grep/sed/awk), and -- like gawk -- no concurrency primitive at all,
# so this is _std only. That, and the speed, are the finding.
#
# LC_ALL=C keeps ${,,} and the glob match byte/ASCII-exact (matches grep -F's
# literal, regex-free semantics). The quoted "$needle" in the glob is literal,
# so pattern metacharacters (a.b, [x], a*b) are matched verbatim, not as globs.
LC_ALL=C
shopt -s dotglob nullglob

ci=0
matched=0
multi=0
needle=
out=

search_file() {
  local f=$1 line cmp
  # binary skip: read up to first NUL; success (exit 0) means a NUL was found.
  if IFS= read -r -d '' _ < "$f"; then return; fi
  while IFS= read -r line || [[ -n $line ]]; do
    if (( ci )); then cmp=${line,,}; else cmp=$line; fi
    if [[ $cmp == *"$needle"* ]]; then
      matched=1
      if (( multi )); then out+="$f:$line"$'\n'; else out+="$line"$'\n'; fi
    fi
  done < "$f"
}

walk() {
  local dir=$1 e
  for e in "$dir"/*; do
    [[ -L $e ]] && continue                 # don't follow symlinks (grep -r)
    if   [[ -d $e ]]; then walk "$e"
    elif [[ -f $e ]]; then search_file "$e"
    fi
  done
}

main() {
  local r=0 no_more=0 have_pat=0 a pat= i c ; local -a paths=()
  for a in "$@"; do
    if (( ! no_more )) && [[ $a == -* && $a != - ]]; then
      if [[ $a == -- ]]; then no_more=1; continue; fi
      for (( i=1; i<${#a}; i++ )); do
        c=${a:i:1}
        case $c in
          i) ci=1 ;;
          r) r=1 ;;
          *) printf 'usage: bashgrep_std [-r] [-i] PATTERN PATH...\n' >&2; return 2 ;;
        esac
      done
    elif (( ! have_pat )); then
      pat=$a; have_pat=1
    else
      paths+=("$a")
    fi
  done
  if (( ! have_pat )) || (( ${#paths[@]} == 0 )); then
    printf 'usage: bashgrep_std [-r] [-i] PATTERN PATH...\n' >&2; return 2
  fi

  needle=$pat
  (( ci )) && needle=${needle,,}
  (( r || ${#paths[@]} > 1 )) && multi=1

  local p
  for p in "${paths[@]}"; do
    if   [[ -d $p ]]; then (( r )) && walk "$p"
    elif [[ -f $p ]]; then search_file "$p"
    fi
  done

  printf '%s' "$out"
  (( matched )) && return 0 || return 1
}

main "$@"
