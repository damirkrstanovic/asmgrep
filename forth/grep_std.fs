\ forthgrep_std - literal (fixed-string) grep clone in gforth 0.7.3.
\ Mirrors python/grep_std.py: whole-file read, literal substring scan via a
\ hand-written byte search, NUL-in-first-64KB binary skip, recursive walk,
\ -i ASCII fold, multi-file PATH: prefix. Single-threaded.
\
\ Args are consumed with next-arg (which already skips gforth + the script
\ path). Exit codes via (bye): 0 match, 1 no match, 2 usage error.
\
\ LIMITATION (documented, same as the J impl in this repo): gforth 0.7.3 does
\ not expose lstat / symlink detection portably. The recursive walk therefore
\ does NOT skip symlinks (it would follow them). The harness fixtures contain
\ no symlinks, so behavior is identical to grep -r there.

\ ---------------------------------------------------------------- constants
10    constant LF
0     constant NUL
65536 constant PEEK

\ ---------------------------------------------------------------- lower table
\ 256-byte table: bytes 'A'..'Z' (65..90) -> +32, others identity.
create lowtab 256 allot
: init-lowtab ( -- )
  256 0 ?do
    i  dup 65 >= over 90 <= and if 32 + then
    i lowtab + c!
  loop ;
init-lowtab
: lc ( c -- c' ) lowtab + c@ ;

\ ---------------------------------------------------------------- output accum
\ Growable output buffer; flushed once at end with type (raw bytes).
variable outbuf  variable outcap  variable outlen
: out-init ( -- ) 65536 dup allocate throw outbuf ! outcap ! 0 outlen ! ;
: out-grow ( need -- )                  \ ensure outlen+need fits capacity
  outlen @ + outcap @ over < if
    begin dup outcap @ > while outcap @ 2* outcap ! repeat drop
    outbuf @ outcap @ resize throw outbuf !
  else drop then ;
: out-bytes ( c-addr u -- )
  dup out-grow
  dup >r  outbuf @ outlen @ +  swap move
  outlen @ r> + outlen ! ;
: out-c ( c -- )
  1 out-grow  outbuf @ outlen @ + c!  outlen @ 1+ outlen ! ;
: out-flush ( -- ) outlen @ if outbuf @ outlen @ type then ;

\ ---------------------------------------------------------------- file buffer
variable fbuf  variable fcap  variable flen
: fbuf-init ( -- ) 65536 dup allocate throw fbuf ! fcap ! 0 flen ! ;
: fbuf-need ( n -- )
  dup fcap @ > if
    fcap @ begin 2dup <= while 2* repeat nip fcap !
    fbuf @ fcap @ resize throw fbuf !
  else drop then ;

\ read whole file into fbuf, set flen. ( c-addr u -- ok )
: read-whole ( c-addr u -- ok )
  r/o open-file if drop false exit then  >r
  r@ file-size if r> close-file drop false exit then  drop  ( size )
  dup fbuf-need
  fbuf @ over r@ read-file               ( size nread ior )
  if 2drop r> close-file drop false exit then
  nip flen !
  r> close-file drop  true ;

\ ---------------------------------------------------------------- pattern
variable patbuf  variable patlen        \ folded pattern bytes
variable ci      variable multi         \ flags (-1/0)

\ ---------------------------------------------------------------- byte search
\ b@ : haystack byte at i, folded if ci.  ( i -- c )
: b@ ( i -- c ) fbuf @ + c@  ci @ if lc then ;

\ match-at: does folded pattern equal haystack at p ?  ( p -- flag )
: match-at { p -- flag }
  patlen @ 0= if true exit then
  patlen @ 0 ?do
    p i + b@  patbuf @ i + c@  <> if false unloop exit then
  loop  true ;

\ find-needle: first match index >= pos, else -1. empty needle => pos.
: find-needle { pos -- idx }
  patlen @ 0= if pos exit then
  flen @ patlen @ -  dup 0< if drop -1 exit then  ( last-start )
  dup pos < if drop -1 exit then                  \ empty range guard
  1+  pos ?do  i match-at if i unloop exit then  loop  -1 ;

\ find-lf-from: index of first LF at/after m, else flen. ( m -- idx )
: find-lf-from { m -- idx }
  flen @ m ?do  i fbuf @ + c@ LF = if i unloop exit then  loop  flen @ ;

\ rfind-lf: index of last LF in [0,m), else -1; returns that+1 (line start).
: line-start { m -- ls }
  0  m 0 ?do  i fbuf @ + c@ LF = if drop i 1+ then  loop ;

\ ---------------------------------------------------------------- search file
\ ( c-addr u -- matched )   appends emitted lines to outbuf.
: search-file { addr u -- matched }
  addr u read-whole 0= if false exit then
  flen @ 0= if false exit then
  \ binary skip: NUL within first PEEK bytes
  flen @ PEEK min  0 ?do  i fbuf @ + c@ NUL = if false unloop exit then  loop
  false { matched }
  0 { pos }
  begin pos flen @ <= while
    pos find-needle { m }
    m 0< if matched exit then
    \ phantom-line guard: m==n and n>0 and last byte is LF -> stop
    m flen @ = flen @ 0> and
      flen @ 1- fbuf @ + c@ LF = and
      if matched exit then
    m line-start { ls }
    m find-lf-from { le }
    true to matched
    multi @ if  addr u out-bytes  [char] : out-c  then
    fbuf @ ls +  le ls -  out-bytes
    LF out-c
    le 1+ to pos
  repeat
  matched ;

\ ---------------------------------------------------------------- dir helpers
: is-dir? ( c-addr u -- flag )
  open-dir if drop false else close-dir drop true then ;
: exists? ( c-addr u -- flag )
  file-status nip 0= ;

\ skip "." and ".." . ( c-addr u -- flag )  true => skip
: dot? { addr u -- flag }
  u 1 = if  addr c@ [char] . =  exit  then
  u 2 = if  addr c@ [char] . =  addr 1+ c@ [char] . =  and  exit  then
  false ;

\ join base+"/"+name into dest buffer. ( dest base u name u2 -- dest len )
: path-join { dest base u name u2 -- dest len }
  base dest u move
  [char] / dest u + c!
  name  dest u + 1+  u2 move
  dest  u u2 + 1+ ;

\ Recursive walk. We must copy the base path into a fresh buffer BEFORE
\ read-dir, then rejoin each entry. Recursion uses allocate so each depth has
\ its own joined-path storage (no fixed scratch clobbering).
\ ( c-addr u -- matched )
variable wnlen
defer walk
: (walk) { base blen -- matched }
  base blen is-dir? 0= if false exit then
  base blen open-dir if drop false exit then  >r
  false { matched }
  \ name read buffer (per call)
  1024 allocate throw { nbuf }
  \ joined-path buffer (per call)
  4096 allocate throw { jbuf }
  begin
    nbuf 1024 r@ read-dir throw          \ nlen flag
  while                                  \ nlen
    wnlen !
    nbuf wnlen @ dot? 0= if
      jbuf base blen nbuf wnlen @ path-join  \ jb jl
      2dup is-dir? if
        walk if true to matched then
      else
        search-file if true to matched then
      then
    then
  repeat
  drop
  jbuf free throw  nbuf free throw
  r> close-dir drop  matched ;
' (walk) is walk

\ ---------------------------------------------------------------- arg parse
variable havepat
variable rflag
variable nomore
variable rawpat        \ raw (unfolded) pattern addr
variable rawpatlen
\ path list: array of (addr,len) pairs.
1024 constant PLCAP
create plist  PLCAP 2* cells allot
variable pcount

\ copy a transient string into heap. ( c-addr u -- a u )
: heap, ( c-addr u -- a u )
  dup allocate throw            \ c-addr u dest
  dup >r                        \ c-addr u dest          R: dest
  swap                          \ c-addr dest u
  dup >r                        \ c-addr dest u          R: dest u
  move                          \                        R: dest u
  r> r> swap ;                  \ dest u

: add-path ( c-addr u -- )
  heap,                         \ a u
  pcount @ 2* cells plist +     \ a u slot
  dup >r cell+ !                \ a            R: slot   (store len at slot+cell)
  r> !                          \ store addr at slot
  1 pcount +! ;
: path@ ( i -- a u )
  2* cells plist +  dup @ swap cell+ @ ;

\ fold raw pattern into patbuf (call AFTER ci is finalized).
: fold-pattern ( -- )
  rawpatlen @ dup patlen !
  dup allocate throw patbuf !
  0 ?do
    rawpat @ i + c@  ci @ if lc then
    patbuf @ i + c!
  loop ;

: usage-die ( -- )
  s" usage: forthgrep_std [-r] [-i] PATTERN PATH..." stderr write-line drop
  2 (bye) ;

\ parse a flag bundle minus the leading '-'. ( c-addr u -- )
: parse-flags ( c-addr u -- )
  0 ?do
    dup i + c@
    case
      [char] i of -1 ci ! endof
      [char] r of -1 rflag ! endof
      drop usage-die
    endcase
  loop drop ;

\ is this arg a flag bundle?  ( c-addr u -- c-addr u flag )
\   flag iff: not nomore, u>=1, first byte '-', and not the lone "-".
: is-flag? ( c-addr u -- c-addr u flag )
  nomore @ if false exit then
  dup 1 < if false exit then
  over c@ [char] - <> if false exit then
  dup 1 = if false exit then          \ lone "-" is not a flag
  true ;

: parse-args ( -- )
  0 havepat ! 0 rflag ! 0 ci ! 0 pcount ! 0 nomore !
  begin
    next-arg over 0<>                    ( c-addr u flag )  \ addr=0 => end
  while                                  ( c-addr u )
    2dup s" --" compare 0= nomore @ 0= and if
      2drop  -1 nomore !
    else
      is-flag? if
        ( c-addr u )  1 /string parse-flags
      else
        ( c-addr u )
        havepat @ if
          add-path
        else
          heap, rawpatlen ! rawpat !  -1 havepat !
        then
      then
    then
  repeat
  2drop ;

\ ---------------------------------------------------------------- main
: run ( -- exit-code )
  parse-args
  havepat @ 0= if usage-die then
  pcount @ 0= if usage-die then
  fold-pattern
  rflag @ pcount @ 1 > or  if -1 else 0 then  multi !
  out-init  fbuf-init
  false { matched }
  pcount @ 0 ?do
    i path@ 2dup exists? if          ( a u )
      2dup is-dir? if
        rflag @ if walk if true to matched then else 2drop then
      else
        search-file if true to matched then
      then
    else 2drop then
  loop
  out-flush
  matched if 0 else 1 then ;

run (bye)
