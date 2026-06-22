! fortgrep_std_mt_tuned - idiomatic + threads + per-thread REUSED growable
! buffer + PREFIX binary-check. One `!$omp parallel` region; each thread owns
! its own `data`/`low`/`obuf` allocatables (declared private and allocated ONCE
! at the top of the region, then reused across every file the thread handles via
! a shared `!$omp do schedule(dynamic)`). Each file: read a 64 KB prefix first,
! NUL-check it, read the remainder only if the prefix passed. Per-file output
! flushed under `!$omp critical`.
module posix_walk
  use iso_c_binding
  implicit none

  interface
    function c_opendir(name) bind(C, name="opendir") result(dp)
      import :: c_ptr, c_char
      character(kind=c_char), intent(in) :: name(*)
      type(c_ptr) :: dp
    end function c_opendir

    function c_readdir(dp) bind(C, name="readdir") result(ep)
      import :: c_ptr
      type(c_ptr), value :: dp
      type(c_ptr) :: ep
    end function c_readdir

    function c_closedir(dp) bind(C, name="closedir") result(r)
      import :: c_ptr, c_int
      type(c_ptr), value :: dp
      integer(c_int) :: r
    end function c_closedir

    function c_lstat(path, buf) bind(C, name="lstat") result(r)
      import :: c_char, c_int8_t, c_int
      character(kind=c_char), intent(in) :: path(*)
      integer(c_int8_t), intent(out) :: buf(*)
      integer(c_int) :: r
    end function c_lstat

    function c_strlen(s) bind(C, name="strlen") result(n)
      import :: c_ptr, c_size_t
      type(c_ptr), value :: s
      integer(c_size_t) :: n
    end function c_strlen
  end interface

  integer, parameter :: S_IFMT  = int(o'170000')
  integer, parameter :: S_IFDIR = int(o'040000')
  integer, parameter :: S_IFREG = int(o'100000')
  integer, parameter :: S_IFLNK = int(o'120000')

contains

  function lstat_mode(path) result(mode)
    character(len=*), intent(in) :: path
    integer :: mode
    integer(c_int8_t) :: buf(144)
    integer(c_int) :: r
    character(kind=c_char, len=:), allocatable :: cpath
    cpath = path // c_null_char
    mode = 0
    r = c_lstat(cpath, buf)
    if (r /= 0) return
    mode = iand(int(buf(25)), 255) + ishft(iand(int(buf(26)),255), 8) + &
           ishft(iand(int(buf(27)),255), 16) + ishft(iand(int(buf(28)),255), 24)
  end function lstat_mode

  logical function is_dir(mode)
    integer, intent(in) :: mode
    is_dir = (iand(mode, S_IFMT) == S_IFDIR)
  end function is_dir

  logical function is_reg(mode)
    integer, intent(in) :: mode
    is_reg = (iand(mode, S_IFMT) == S_IFREG)
  end function is_reg

  logical function is_lnk(mode)
    integer, intent(in) :: mode
    is_lnk = (iand(mode, S_IFMT) == S_IFLNK)
  end function is_lnk

  function dirent_name(ep) result(name)
    type(c_ptr), intent(in) :: ep
    character(len=:), allocatable :: name
    integer(c_int8_t), pointer :: hdr(:), nbytes(:)
    type(c_ptr) :: namep
    integer(c_size_t) :: n
    integer :: i
    call c_f_pointer(ep, hdr, [int(20, c_size_t)])
    namep = c_loc(hdr(20))
    n = c_strlen(namep)
    allocate(character(len=int(n)) :: name)
    if (n == 0) return
    call c_f_pointer(namep, nbytes, [n])
    do i = 1, int(n)
      name(i:i) = achar(iand(int(nbytes(i)), 255))
    end do
  end function dirent_name

end module posix_walk


module grep_core
  use iso_c_binding
  use posix_walk
  implicit none

  character(len=:), allocatable :: g_pat, g_lpat
  logical :: g_ci = .false., g_r = .false., g_multi = .false.
  logical :: g_matched = .false.
  integer, parameter :: PREFIX = 65536
  integer :: g_out_unit

  character(len=:), allocatable :: g_files(:)
  integer :: g_nfiles = 0

  ! Per-thread reused state. Rather than rely on OpenMP `private` allocatables
  ! (fragile under gfortran when reallocated inside a called subroutine), we use
  ! a shared array indexed by omp_get_thread_num(): each thread touches only its
  ! own slot, so the buffers are genuinely reused across files with no sharing.
  type :: worker_t
    character(len=:), allocatable :: data
    character(len=:), allocatable :: low
    character(len=:), allocatable :: obuf
  end type worker_t

contains

  function ascii_lower(s) result(o)
    character(len=*), intent(in) :: s
    character(len=len(s)) :: o
    integer :: i, c
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (c >= 65 .and. c <= 90) then
        o(i:i) = achar(c + 32)
      else
        o(i:i) = s(i:i)
      end if
    end do
  end function ascii_lower

  subroutine add_file(path)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: tmp(:)
    integer :: cap, newcap, plen
    plen = len(path)
    if (.not. allocated(g_files)) then
      allocate(character(len=max(plen,1)) :: g_files(64))
    end if
    cap = size(g_files)
    if (g_nfiles >= cap .or. plen > len(g_files)) then
      newcap = cap
      if (g_nfiles >= cap) newcap = cap * 2
      allocate(character(len=max(plen, len(g_files))) :: tmp(newcap))
      tmp(1:g_nfiles) = g_files(1:g_nfiles)
      call move_alloc(tmp, g_files)
    end if
    g_nfiles = g_nfiles + 1
    g_files(g_nfiles) = path
  end subroutine add_file

  recursive subroutine walk_dir(dir)
    character(len=*), intent(in) :: dir
    type(c_ptr) :: dp, ep
    character(len=:), allocatable :: name, full
    integer :: mode
    integer(c_int) :: rc
    character(kind=c_char, len=:), allocatable :: cdir

    cdir = dir // c_null_char
    dp = c_opendir(cdir)
    if (.not. c_associated(dp)) return
    do
      ep = c_readdir(dp)
      if (.not. c_associated(ep)) exit
      name = dirent_name(ep)
      if (name == '.' .or. name == '..') cycle
      full = trim(dir) // '/' // name
      mode = lstat_mode(full)
      if (mode == 0) cycle
      if (is_lnk(mode)) cycle
      if (is_dir(mode)) then
        call walk_dir(full)
      else if (is_reg(mode)) then
        call add_file(full)
      end if
    end do
    rc = c_closedir(dp)
  end subroutine walk_dir

  subroutine handle_path(path)
    character(len=*), intent(in) :: path
    integer :: mode
    mode = lstat_mode(path)
    if (mode == 0) return
    if (is_dir(mode)) then
      if (g_r) call walk_dir(path)
    else if (is_reg(mode)) then
      call add_file(path)
    end if
  end subroutine handle_path

  ! grow an allocatable char buffer to at least n bytes, preserving nothing
  subroutine ensure_cap(buf, n)
    character(len=:), allocatable, intent(inout) :: buf
    integer, intent(in) :: n
    integer(c_int64_t) :: newlen
    if (allocated(buf)) then
      if (len(buf) >= n) return
      deallocate(buf)
    end if
    ! 64-bit arithmetic: n + n/2 + 4096 overflows a 32-bit int for n > ~1.4 GB
    ! (wraps negative -> bogus huge allocation -> crash).
    newlen = int(n, c_int64_t) + int(n, c_int64_t)/2 + 4096
    allocate(character(len=newlen) :: buf)
  end subroutine ensure_cap

  ! TUNED search: reuses caller-supplied data/low/obuf buffers (per-thread).
  ! Reads a 64 KB prefix, NUL-checks it, reads the rest only if it passes.
  subroutine search_file(path, w)
    character(len=*), intent(in) :: path
    type(worker_t), intent(inout) :: w
    character(len=:), allocatable :: needle, pfx
    integer :: n, peek, i, m, ls, le, pos, nlen, rel, olen, ocap
    integer :: u, ios
    integer(c_int64_t) :: fsize
    logical :: exists, local_match

    inquire(file=path, exist=exists, size=fsize)
    if (.not. exists) return
    if (fsize <= 0) return
    n = int(fsize)

    open(newunit=u, file=path, access='stream', form='unformatted', &
         action='read', status='old', iostat=ios)
    if (ios /= 0) return

    ! Reuse the per-thread buffer (grow-only). Read ONLY the prefix first via
    ! a positioned stream read, NUL-check it, and read the remainder only if it
    ! passes. No c_loc-of-substring (which can materialise an aliasing temporary
    ! and corrupt the heap under threads) — plain Fortran stream I/O is safe.
    ! Allocate ONLY the prefix first and NUL-check it, so a huge binary (e.g. a
    ! 1.5 GB .git pack) is skipped at 64 KB without ever allocating its full size.
    peek = min(n, PREFIX)
    call ensure_cap(w%data, peek)
    read(u, pos=1, iostat=ios) w%data(1:peek)
    if (ios /= 0) then
      close(u)
      return
    end if

    ! NUL-check prefix; skip if binary
    do i = 1, peek
      if (w%data(i:i) == achar(0)) then
        close(u)
        return
      end if
    end do

    ! text: grow to full size and read the whole file (ensure_cap preserves
    ! nothing, so re-read from pos=1). Binary files never reach here.
    if (n > peek) then
      call ensure_cap(w%data, n)
      read(u, pos=1, iostat=ios) w%data(1:n)
      if (ios /= 0) n = peek
    end if
    close(u)

    if (g_ci) then
      call ensure_cap(w%low, n)
      w%low(1:n) = ascii_lower(w%data(1:n))
      needle = g_lpat
    else
      needle = g_pat
    end if
    nlen = len(needle)

    if (g_multi) then
      pfx = trim(path) // ':'
    else
      pfx = ''
    end if

    call ensure_cap(w%obuf, max(n, 64))
    ocap = len(w%obuf)
    olen = 0
    local_match = .false.

    pos = 1
    do while (pos <= n)
      if (nlen == 0) then
        m = pos
      else
        if (g_ci) then
          rel = index(w%low(pos:n), needle)
        else
          rel = index(w%data(pos:n), needle)
        end if
        if (rel == 0) exit
        m = pos + rel - 1
      end if
      ls = 1
      do i = m - 1, 1, -1
        if (w%data(i:i) == achar(10)) then
          ls = i + 1
          exit
        end if
      end do
      le = n + 1
      do i = m, n
        if (w%data(i:i) == achar(10)) then
          le = i
          exit
        end if
      end do
      local_match = .true.
      if (g_multi) call buf_append(w%obuf, ocap, olen, pfx)
      if (le > ls) call buf_append(w%obuf, ocap, olen, w%data(ls:le-1))
      call buf_append(w%obuf, ocap, olen, achar(10))
      pos = le + 1
    end do

    if (local_match) then
      !$omp critical (outblock)
      g_matched = .true.
      if (olen > 0) write(g_out_unit) w%obuf(1:olen)
      !$omp end critical (outblock)
    end if
  end subroutine search_file

  subroutine buf_append(buf, cap, olen, s)
    character(len=:), allocatable, intent(inout) :: buf
    integer, intent(inout) :: cap, olen
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: tmp
    integer :: need
    if (len(s) == 0) return
    need = olen + len(s)
    if (need > cap) then
      allocate(character(len=need*2 + 64) :: tmp)
      tmp(1:olen) = buf(1:olen)
      call move_alloc(tmp, buf)
      cap = len(buf)
    end if
    buf(olen+1:olen+len(s)) = s
    olen = olen + len(s)
  end subroutine buf_append

end module grep_core


program grep_mt_tuned
  use iso_fortran_env, only: error_unit
  use grep_core
  use posix_walk
  use omp_lib
  implicit none

  character(len=:), allocatable :: arg, pat
  character(len=:), allocatable :: paths(:)
  integer :: argc, i, k, npaths, alen, maxlen, nt
  logical :: no_more, pat_set
  character(len=4096) :: tmp

  ! per-thread reused buffers: a shared array, one worker_t slot per thread,
  ! indexed by omp_get_thread_num(). Each thread only ever touches its own slot,
  ! so the buffers are reused across files without OpenMP private-allocatable
  ! fragility (which corrupts the heap under gfortran when reallocated inside a
  ! called routine).
  type(worker_t), allocatable :: workers(:)
  integer :: tid

  argc = command_argument_count()
  no_more = .false.
  pat_set = .false.
  npaths = 0

  maxlen = 1
  do i = 1, argc
    call get_command_argument(i, tmp, alen)
    if (alen > maxlen) maxlen = alen
  end do
  allocate(character(len=maxlen) :: paths(max(argc,1)))

  do i = 1, argc
    call get_command_argument(i, tmp, alen)
    arg = tmp(1:alen)
    if ((.not. no_more) .and. alen >= 2 .and. arg(1:1) == '-') then
      if (arg == '--') then
        no_more = .true.
        cycle
      end if
      do k = 2, alen
        select case (arg(k:k))
        case ('i')
          g_ci = .true.
        case ('r')
          g_r = .true.
        case default
          call usage()
        end select
      end do
    else if (.not. pat_set) then
      pat = arg
      pat_set = .true.
    else
      npaths = npaths + 1
      paths(npaths) = arg
    end if
  end do

  if ((.not. pat_set) .or. npaths == 0) call usage()

  g_pat = pat
  g_lpat = ascii_lower(pat)
  g_multi = g_r .or. (npaths > 1)

  open(newunit=g_out_unit, file='/dev/stdout', access='stream', &
       form='unformatted', action='write')

  do i = 1, npaths
    call handle_path(trim(paths(i)))
  end do

  nt = omp_get_max_threads()
  if (nt < 1) nt = 1
  allocate(workers(0:nt-1))     ! one reused buffer-set per thread slot

  ! Shared do-loop: each thread reuses workers(tid) across every file it runs.
  ! ensure_cap only grows the buffers, so they persist (true per-thread reuse).
  !$omp parallel num_threads(nt) private(i, tid)
  tid = omp_get_thread_num()
  !$omp do schedule(dynamic)
  do i = 1, g_nfiles
    call search_file(trim(g_files(i)), workers(tid))
  end do
  !$omp end do
  !$omp end parallel

  flush(g_out_unit)
  close(g_out_unit)

  if (g_matched) then
    call exit(0)
  else
    call exit(1)
  end if

contains

  subroutine usage()
    write(error_unit, '(A)') 'usage: fortgrep [-r] [-i] PATTERN PATH...'
    call exit(2)
  end subroutine usage

end program grep_mt_tuned
