! fortgrep_std - idiomatic single-threaded Fortran: recursive directory walk
! via POSIX opendir/readdir/lstat (iso_c_binding), whole-file stream read, and
! the index() intrinsic for literal substring search. Stdlib all the way; no
! threads, no hand-rolled SIMD. Byte-exact with `grep -F`.
module posix_walk
  use iso_c_binding
  implicit none

  ! --- dirent (x86-64 Linux glibc): d_name at offset 19. We bind readdir to a
  !     c_ptr and pull d_name out via c_f_pointer on the byte after offset 18. ---
  ! --- struct stat (x86-64 glibc): st_mode is a 4-byte field at offset 24. We
  !     pass a 144-byte int8 buffer to lstat and read st_mode from offset 24. ---

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

  ! glibc st_mode bit masks
  integer, parameter :: S_IFMT  = int(o'170000')
  integer, parameter :: S_IFDIR = int(o'040000')
  integer, parameter :: S_IFREG = int(o'100000')
  integer, parameter :: S_IFLNK = int(o'120000')

contains

  ! Return st_mode (4 bytes at offset 24) via lstat. mode=0 on failure.
  function lstat_mode(path) result(mode)
    character(len=*), intent(in) :: path
    integer :: mode
    integer(c_int8_t) :: buf(144)
    integer(c_int) :: r
    integer :: b0, b1, b2, b3
    character(kind=c_char, len=:), allocatable :: cpath
    cpath = path // c_null_char
    mode = 0
    r = c_lstat(cpath, buf)
    if (r /= 0) return
    ! st_mode at byte offset 24 (1-based index 25), 4 bytes little-endian.
    b0 = iand(int(buf(25)), 255)
    b1 = iand(int(buf(26)), 255)
    b2 = iand(int(buf(27)), 255)
    b3 = iand(int(buf(28)), 255)
    mode = b0 + ishft(b1, 8) + ishft(b2, 16) + ishft(b3, 24)
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

  ! Read the NUL-terminated d_name (offset 19) out of a dirent pointed by ep.
  function dirent_name(ep) result(name)
    type(c_ptr), intent(in) :: ep
    character(len=:), allocatable :: name
    integer(c_int8_t), pointer :: hdr(:), nbytes(:)
    type(c_ptr) :: namep
    integer(c_size_t) :: n
    integer :: i
    ! d_name begins at byte offset 19 (1-based 20) within struct dirent.
    ! Map just enough to reach the name start, find its address, strlen it,
    ! then map exactly the name bytes (avoids reading past a too-small window).
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

contains

  ! length-preserving ASCII lowercase copy
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

  subroutine search_file(path)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: data, hay, needle, pfx
    integer(c_int64_t) :: fsize
    integer :: u, ios, n, peek, i, m, ls, le, pos, nlen, rel
    logical :: exists

    inquire(file=path, exist=exists, size=fsize)
    if (.not. exists) return
    if (fsize <= 0) return
    n = int(fsize)

    open(newunit=u, file=path, access='stream', form='unformatted', &
         action='read', status='old', iostat=ios)
    if (ios /= 0) return
    allocate(character(len=n) :: data)
    read(u, iostat=ios) data
    close(u)
    if (ios /= 0) return

    ! binary check on the prefix
    peek = min(n, PREFIX)
    do i = 1, peek
      if (data(i:i) == achar(0)) return
    end do

    if (g_ci) then
      hay = ascii_lower(data)
      needle = g_lpat
    else
      hay = data
      needle = g_pat
    end if
    nlen = len(needle)

    if (g_multi) then
      pfx = trim(path) // ':'
    else
      pfx = ''
    end if

    pos = 1
    do while (pos <= n)
      if (nlen == 0) then
        m = pos
      else
        rel = index(hay(pos:), needle)
        if (rel == 0) exit
        m = pos + rel - 1
      end if
      ! line start: 1 + index of last \n before m, else 1
      ls = 1
      do i = m - 1, 1, -1
        if (data(i:i) == achar(10)) then
          ls = i + 1
          exit
        end if
      end do
      ! line end: index of first \n at/after m, exclusive; else n+1
      le = n + 1
      do i = m, n
        if (data(i:i) == achar(10)) then
          le = i
          exit
        end if
      end do
      g_matched = .true.
      if (g_multi) call out_bytes(pfx)
      if (le > ls) call out_bytes(data(ls:le-1))
      call out_bytes(achar(10))
      pos = le + 1
    end do
  end subroutine search_file

  ! recursive walk: regular files only, no symlink following
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
      if (is_lnk(mode)) cycle          ! don't follow symlinks
      if (is_dir(mode)) then
        call walk_dir(full)
      else if (is_reg(mode)) then
        call search_file(full)
      end if
    end do
    rc = c_closedir(dp)
  end subroutine walk_dir

  ! dispatch a top-level PATH argument
  subroutine handle_path(path)
    character(len=*), intent(in) :: path
    integer :: mode
    mode = lstat_mode(path)
    if (mode == 0) return
    if (is_dir(mode)) then
      if (g_r) call walk_dir(path)
    else if (is_reg(mode)) then
      call search_file(path)
    else if (is_lnk(mode)) then
      ! top-level symlink: resolve via stat semantics is not required by spec;
      ! treat plainly — most cases hit regular files. Skip to match lstat-only.
      continue
    end if
  end subroutine handle_path

  ! buffered stdout via stream I/O on /dev/stdout
  subroutine out_bytes(s)
    character(len=*), intent(in) :: s
    if (len(s) == 0) return
    write(g_out_unit) s
  end subroutine out_bytes

end module grep_core


program grep_std
  use iso_fortran_env, only: error_unit
  use grep_core
  use posix_walk
  implicit none

  character(len=:), allocatable :: arg, pat
  character(len=:), allocatable :: paths(:)
  integer :: argc, i, k, npaths, alen, maxlen
  logical :: no_more, pat_set
  character(len=4096) :: tmp

  ! collect & parse args
  argc = command_argument_count()
  no_more = .false.
  pat_set = .false.
  npaths = 0

  ! first pass: max length for paths array allocation
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

  ! open buffered stdout stream
  open(newunit=g_out_unit, file='/dev/stdout', access='stream', &
       form='unformatted', action='write')

  do i = 1, npaths
    call handle_path(trim(paths(i)))
  end do

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

end program grep_std
