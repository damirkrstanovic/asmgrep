NB. jgrep_std - literal (fixed-string) grep clone in J (jsoftware).
NB. Mirrors python/grep_std.py: whole-file read, literal substring scan via
NB. E. (find), NUL-in-first-64KB binary skip, recursive walk, -i ASCII fold,
NB. multi-file PATH: prefix. Single-threaded (no idiomatic concurrency).
NB. Run via bin/jgrep_std launcher (jconsole ... </dev/null). MUST exit at end.

LF    =: 10 { a.
NUL   =: 0  { a.
COLON =: ':'

NB. ASCII-only lowercase fold: bytes 65..90 -> +32, applied by indexing a.
tolower =: 3 : 0
  t =. a.
  src =. 65 + i. 26
  t =. ((97 + i. 26){a.) (src}) t
  t {~ a. i. y                   NB. translate each byte through table t
)

NB. 1!:2 <2 / <4 append a newline per write; /dev/stdout writes raw bytes.
toout =: 3 : 'y 1!:2 <''/dev/stdout'''   NB. raw bytes to stdout
toerr =: 3 : 'y 1!:2 <''/dev/stderr'''   NB. raw bytes to stderr

USAGE =: 'usage: jgrep_std [-r] [-i] PATTERN PATH...' , LF

die =: 3 : 0
  toerr USAGE
  2!:55 (2)
)

NB. -------- search a single file. Returns 1 if matched, appends to OUT --------
NB. globals: PAT LPAT CI MULTI OUT (boxed-string accumulator)
search_file =: 3 : 0
  path =. y
  dat =. 1!:1 < path
  if. 0 = # dat do. 0 return. end.
  peek =. (65536 <. # dat) {. dat
  if. +./ peek = NUL do. 0 return. end.          NB. binary skip
  n =. # dat
  if. CI do. hay =. tolower dat [ needle =. LPAT
  else.     hay =. dat          [ needle =. PAT end.

  nl =. I. dat = LF                              NB. newline positions
  if. 0 = # needle do.
    NB. empty pattern: one match per line-start (pos 0 and after each LF),
    NB. but no phantom line after a trailing LF.
    starts =. 0 , (nl + 1)
    starts =. starts (#~ (< & n)) starts
  else.
    m =. n {. needle E. hay                      NB. length-n boolean
    starts =. I. m
  end.
  if. 0 = # starts do. 0 return. end.

  matched =. 0
  lastle =. _1
  for_mm. starts do.
    NB. phantom guard
    if. (mm = n) *. (n > 0) *. (LF = (n-1) { dat) do. break. end.
    before =. nl (#~ (< & mm)) nl
    ls =. 0
    if. 0 < # before do. ls =. 1 + {: before end.
    after =. nl (#~ (>: & mm)) nl
    le =. n
    if. 0 < # after do. le =. {. after end.
    if. le = lastle do. continue. end.            NB. one line per matching line
    lastle =. le
    matched =. 1
    line =. (le - ls) {. ls }. dat
    if. MULTI do.
      OUT =: OUT , < (>path) , COLON , line , LF
    else.
      OUT =: OUT , < line , LF
    end.
  end.
  matched
)

NB. -------- symlink test via libc readlink (>= 0 only on a symlink). 1!:0
NB. classifies a symlinked dir as 'd' and follows it, but grep -r does NOT
NB. follow symlinks found while recursing -- following one double-counts every
NB. file reachable through a symlinked dir (e.g. immich/fastlane/metadata). ----
islink =: 3 : 0
  buf =. 256 $ ' '
  res =. 'libc.so.6 readlink > x *c *c x' 15!:0 (y;buf;256)
  (>0{res) >: 0
)

NB. -------- recursive walk. Skip symlinks (grep -r doesn't follow them); else
NB. classify by attr col 4 ('d' at index 4 => directory), recurse dirs. -------
walk =: 3 : 0
  base =. y
  matched =. 0
  r =. 1!:0 < base , '/*'
  if. 0 = # r do. 0 return. end.
  names =. 0 {"1 r
  attrs =. 4 {"1 r
  cnt =. # names
  i =. 0
  while. i < cnt do.
    nm =. > i { names
    at =. > i { attrs
    full =. base , '/' , nm
    if. islink full do.
      NB. grep -r does not follow symlinks found while recursing
    elseif. 'd' = 4 { at do.
      if. walk full do. matched =. 1 end.
    elseif. 1 do.
      if. search_file full do. matched =. 1 end.
    end.
    i =. i + 1
  end.
  matched
)

NB. classify a top-level path: 'd' dir, 'f' file/other, '' nonexistent.
NB. 1!:0 follows symlinks (FOLLOW semantics, matching the reference stat()).
top_kind =: 3 : 0
  r =. 1!:0 < y
  if. 0 = # r do. '' return. end.
  at =. > 0 { 4 {"1 r            NB. attr string of the single row
  if. 'd' = 4 { at do. 'd' return. end.
  'f'
)

main =: 3 : 0
  args =. 2 }. ARGV              NB. drop jconsole path + script path
  CI =: 0
  RFLAG =. 0
  pat =. ''
  havepat =. 0
  paths =. 0 $ a:
  nomore =. 0
  for_a. args do.
    s =. > a
    if. (-. nomore) *. (s -: '--') do.
      nomore =. 1
      continue.
    end.
    isflag =. (-. nomore) *. (1 < # s) *. '-' = ({. s , ' ')
    if. isflag do.
      body =. 1 }. s
      for_q. body do.
        c =. > q
        if.   c = 'i' do. CI =: 1
        elseif. c = 'r' do. RFLAG =. 1
        elseif. 1 do. die '' end.
      end.
    else.
      if. havepat = 0 do.
        pat =. s
        havepat =. 1
      else.
        paths =. paths , < s
      end.
    end.
  end.
  if. (havepat = 0) +. (0 = # paths) do. die '' end.

  PAT   =: pat
  LPAT  =: tolower pat
  MULTI =: RFLAG +. (1 < # paths)
  OUT   =: 0 $ a:
  matched =. 0

  for_p. paths do.
    pth =. > p
    k =. top_kind pth
    if.     k -: 'd' do.
      if. RFLAG do. if. walk pth do. matched =. 1 end. end.
    elseif. k -: 'f' do.
      if. search_file pth do. matched =. 1 end.
    end.
  end.

  if. 0 < # OUT do. toout (; OUT) end.
  2!:55 (matched { 1 0)          NB. exit 0 if matched else 1
)

main ''
2!:55 (1)
