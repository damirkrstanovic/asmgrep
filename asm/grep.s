# asmgrep - a fast grep replacement in x86-64 Linux assembly (GNU as, Intel syntax)
#
#   asmgrep [-r] [-i] PATTERN PATH...
#
# Literal substring match (no regex). Optimizations, ripgrep-style:
#   * binary-file skip   - peek for a NUL byte, skip the file (like grep/rg)
#   * buffered output    - one write() per ~64KB, not per matching line
#   * SSE2 rare-byte scan - memchr the least-frequent pattern byte 16B at a time
#   * search-then-locate - find a candidate first, only then locate line bounds
#
# Freestanding: raw syscalls, no libc. SSE2 is baseline on x86-64.
# Exit status: 0 = a line matched, 1 = no match, 2 = usage/IO error.

.intel_syntax noprefix

# ---- syscall numbers ----
.equ SYS_write,       1
.equ SYS_open,        2
.equ SYS_close,       3
.equ SYS_fstat,       5
.equ SYS_mmap,        9
.equ SYS_munmap,      11
.equ SYS_exit,        60
.equ SYS_getdents64,  217
.equ SYS_newfstatat,  262

# ---- flags / constants ----
.equ AT_FDCWD,     -100
.equ O_RDONLY,     0
.equ O_DIRECTORY,  0x10000
.equ PROT_READ,    1
.equ MAP_PRIVATE,  2
.equ S_IFMT,       0xF000
.equ S_IFDIR,      0x4000
.equ S_IFREG,      0x8000
.equ DT_UNKNOWN,   0
.equ DT_DIR,       4
.equ DT_REG,       8
.equ DT_LNK,       10

.equ STAT_MODE,    24
.equ STAT_SIZE,    48
.equ STAT_BYTES,   144

.equ DIRENT_BUFSZ, 8192
.equ PATHBUF_SZ,   4096
.equ PATH_MAX_BUILD, 4000
.equ OUTBUF_SZ,    65536
.equ BIN_PEEK,     65536
.equ PATBUF_SZ,    65536
.equ BMH_MIN,      32          # Boyer-Moore-Horspool only for long patterns;
                               # for short patterns the SIMD scan is far faster
                               # (the scalar skip loop is latency-bound).

# ---- per-thread context (rbp points at one of these during search) ----
.equ CTX_OUTBUF,   0
.equ CTX_OUTLEN,   65536
.equ CTX_CURPP,    65544       # cur_path_ptr
.equ CTX_CURPL,    65552       # cur_path_len
.equ CTX_STAT,     65560       # struct stat (144 bytes)
.equ CTX_READBUF,  65728       # reusable read() buffer for small files
.equ READBUF_SZ,   262144      # 256 KiB: files <= this are read(), not mmap'd
.equ CTX_SIZE,     327872      # 65728 + 262144

.equ SYS_read,     0

.equ MAX_THREADS,  16
.equ THREAD_STACK, 1048576     # 1 MiB per worker stack
.equ PAR_SPAWN,    3           # spawn helpers once this many dirs are queued

# ---- directory-queue arena sizes ----
.equ ARENA_SZ,     134217728   # 128 MiB path-string arena
.equ MAX_DIRS,     1048576

# ---- clone(2) flags for a thread sharing VM/files ----
.equ CLONE_VM,            0x00000100
.equ CLONE_FS,            0x00000200
.equ CLONE_FILES,         0x00000400
.equ CLONE_SIGHAND,       0x00000800
.equ CLONE_THREAD,        0x00010000
.equ CLONE_CHILD_CLEARTID,0x00200000
.equ THREAD_FLAGS, CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_CHILD_CLEARTID

.equ SYS_clone,           56
.equ SYS_munmap2_unused,  0
.equ SYS_mmap_n,          9
.equ SYS_futex,           202
.equ SYS_sched_getaffinity, 204
.equ FUTEX_WAIT,          0
.equ MAP_ANON_PRIV, 0x22       # MAP_PRIVATE|MAP_ANONYMOUS
.equ PROT_RW,       0x3        # PROT_READ|PROT_WRITE

# ============================================================================
.section .rodata
usage:   .ascii "usage: asmgrep [-r] [-i] PATTERN PATH...\n"
usage_end:
colon:   .ascii ":"
newline: .ascii "\n"

# Byte-frequency rank: LOW = rare (good memchr pivot), HIGH = common.
.balign 16
freq_tab:
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 250, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 255, 1, 50, 1, 1, 1, 1, 1, 50, 50, 1, 1, 50, 50, 50, 50
    .byte 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 50, 1, 1, 50, 1, 1
    .byte 1, 66, 33, 45, 50, 80, 38, 36, 58, 63, 20, 23, 48, 41, 61, 65
    .byte 35, 20, 56, 60, 70, 43, 26, 40, 20, 36, 20, 1, 1, 1, 1, 50
    .byte 1, 200, 100, 135, 150, 240, 115, 110, 175, 190, 45, 70, 145, 125, 185, 195
    .byte 105, 38, 170, 180, 210, 130, 80, 120, 40, 108, 35, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1

# ============================================================================
.bss
.lcomm pathbuf,      PATHBUF_SZ
.lcomm statbuf,      STAT_BYTES   # used by the (single-threaded) directory walk
.lcomm pat_lower,    PATBUF_SZ
.lcomm pat_ptr,      8
.lcomm pat_len,      8
.lcomm pat_cmp_ptr,  8
.lcomm off_a,        8         # offset of rare byte A in pattern
.lcomm off_b,        8         # offset of rare byte B (off_b > off_a)
.lcomm dd,           8         # off_b - off_a
# ---- directory work queue (parallel walk) ----
.lcomm arena,        ARENA_SZ  # NUL-terminated directory path strings
.lcomm arena_next,   8         # atomic bump pointer into arena
.lcomm dirq,         8388608   # MAX_DIRS pointers into arena (LIFO stack)
.lcomm dirq_top,     8         # number of queued directories
.lcomm dirq_lock,    4         # spinlock guarding the queue
.lcomm pending,      8         # dirs discovered but not fully processed (atomic)
.lcomm out_lock,     4         # spinlock guarding writes to fd 1
.lcomm n_threads,    8
.lcomm ctxs,         MAX_THREADS * CTX_SIZE
.lcomm tids,         MAX_THREADS * 4   # child-tid futex words (CLONE_CHILD_CLEARTID)
.lcomm cpumask,      128       # sched_getaffinity bitmap
.lcomm opt_i,        1
.lcomm opt_r,        1
.lcomm multi,        1
.lcomm match_found,  1
.lcomm had_error,    1
.lcomm fold_flag,    1
.lcomm use_avx2,     1         # 1 if CPU+OS support AVX2
.lcomm scan_mode,    1         # 0=two-byte filter, 1=single memchr, 2=Boyer-Moore
.lcomm skip_tab,     1024      # BMH bad-character skip table (256 dwords)
.lcomm pa0,          1         # byte A, lower case (or as-is)
.lcomm pa1,          1         # byte A, alternate case
.lcomm pb0,          1         # byte B, lower case (or as-is)
.lcomm pb1,          1         # byte B, alternate case

# ============================================================================
.text
.global _start

# ----------------------------------------------------------------------------
# strlen(rdi) -> rax
# ----------------------------------------------------------------------------
strlen:
    xor rax, rax
1:  cmp byte ptr [rdi+rax], 0
    je  2f
    inc rax
    jmp 1b
2:  ret

# ----------------------------------------------------------------------------
# memchr_b(rdi=ptr, rsi=end, dl=byte) -> rax = ptr to first byte, or 0
# SSE2: 16 bytes per iteration, scalar tail.
# ----------------------------------------------------------------------------
memchr_b:
    movzx eax, dl
    imul  eax, eax, 0x01010101
    movd  xmm1, eax
    pshufd xmm1, xmm1, 0
1:  lea   rcx, [rdi+16]
    cmp   rcx, rsi
    ja    3f
    movdqu xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    test  eax, eax
    jnz   2f
    add   rdi, 16
    jmp   1b
2:  bsf   eax, eax
    add   rdi, rax
    mov   rax, rdi
    ret
3:  cmp   rdi, rsi
    jae   4f
    mov   al, [rdi]
    cmp   al, dl
    je    5f
    inc   rdi
    jmp   3b
4:  xor   rax, rax
    ret
5:  mov   rax, rdi
    ret

# ----------------------------------------------------------------------------
# pivot_find(rdi=ptr, rsi=end) -> rax = ptr to pa0|pa1 byte, or 0
# SSE2 search for either case of byte A (used for 1-char patterns).
# ----------------------------------------------------------------------------
pivot_find:
    movzx eax, byte ptr [rip + pa0]
    imul  eax, eax, 0x01010101
    movd  xmm1, eax
    pshufd xmm1, xmm1, 0
    movzx eax, byte ptr [rip + pa1]
    imul  eax, eax, 0x01010101
    movd  xmm2, eax
    pshufd xmm2, xmm2, 0
1:  lea   rcx, [rdi+16]
    cmp   rcx, rsi
    ja    3f
    movdqu xmm0, [rdi]
    movdqa xmm3, xmm0
    pcmpeqb xmm0, xmm1
    pcmpeqb xmm3, xmm2
    por   xmm0, xmm3
    pmovmskb eax, xmm0
    test  eax, eax
    jnz   2f
    add   rdi, 16
    jmp   1b
2:  bsf   eax, eax
    add   rdi, rax
    mov   rax, rdi
    ret
3:  cmp   rdi, rsi
    jae   4f
    mov   al, [rdi]
    cmp   al, [rip + pa0]
    je    5f
    cmp   al, [rip + pa1]
    je    5f
    inc   rdi
    jmp   3b
4:  xor   rax, rax
    ret
5:  mov   rax, rdi
    ret

# ----------------------------------------------------------------------------
# verify(rdi=start) -> al = 1 if pattern matches at start
# Compares against pat_cmp_ptr; folds haystack bytes when fold_flag.
# ----------------------------------------------------------------------------
verify:
    mov  r8, [rip + pat_len]
    mov  r9, [rip + pat_cmp_ptr]
    xor  rcx, rcx
1:  cmp  rcx, r8
    jae  9f
    mov  al, [rdi + rcx]
    cmp  byte ptr [rip + fold_flag], 0
    je   2f
    cmp  al, 'A'
    jb   2f
    cmp  al, 'Z'
    ja   2f
    add  al, 0x20
2:  cmp  al, [r9 + rcx]
    jne  8f
    inc  rcx
    jmp  1b
8:  xor  al, al
    ret
9:  mov  al, 1
    ret

# ----------------------------------------------------------------------------
# find_match(rdi=floor, rsi=end) -> rax = match-start ptr at/after floor, or 0
# Two-byte SSE2 prefilter: a window byte must equal A (at off_a) AND the byte
# off_b-off_a further along must equal B (at off_b). Survivors are verified.
# 1-char patterns use the single-byte pivot_find path.
# ----------------------------------------------------------------------------
find_match:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov  r12, rdi              # floor
    mov  r13, rsi              # end
    cmp  qword ptr [rip + pat_len], 1
    jne  5f
    # ---- single-byte pattern ----
    mov  rdi, r12
    mov  rsi, r13
    call pivot_find            # rax = match start (case already handled), or 0
    jmp  90f
5:  cmp  byte ptr [rip + scan_mode], 2
    je   70f
    cmp  byte ptr [rip + scan_mode], 1
    jne  10f
    # ---- rare A byte: single-byte memchr + verify ----
    mov  r14, r12
6:  mov  rdi, r14
    mov  rsi, r13
    call pivot_find            # next A position, or 0
    test rax, rax
    jz   80f
    mov  rbx, rax              # A position
    mov  rax, rbx
    sub  rax, [rip + off_a]    # candidate start
    cmp  rax, r12
    jb   7f                    # before floor
    mov  rdx, rax
    add  rdx, [rip + pat_len]
    cmp  rdx, r13
    ja   80f                   # cannot fit
    mov  rdi, rax
    push rax
    call verify
    pop  rdx
    test al, al
    jz   7f
    mov  rax, rdx
    jmp  90f
7:  lea  r14, [rbx + 1]
    jmp  6b
    # ---- Boyer-Moore-Horspool: skip by bad-character table ----
70: mov  rax, [rip + pat_len]
    lea  r14, [r12 + rax]
    dec  r14                   # ptr to last byte of first window
    mov  r9, [rip + pat_cmp_ptr]
    movzx ebx, byte ptr [r9 + rax - 1]   # pattern's last byte (folded)
    lea  r11, [rip + skip_tab]
71: cmp  r14, r13
    jae  80f
    movzx ecx, byte ptr [r14]
    cmp  byte ptr [rip + fold_flag], 0
    je   72f
    cmp  cl, 'A'
    jb   72f
    cmp  cl, 'Z'
    ja   72f
    add  cl, 0x20
72: mov  r10d, ecx            # keep folded c (verify clobbers rcx)
    cmp  cl, bl
    jne  73f
    mov  rax, r14
    sub  rax, [rip + pat_len]
    inc  rax                   # candidate start = r14 - (m-1)
    mov  rdi, rax
    push rax
    call verify
    pop  rdx
    test al, al
    jz   73f
    mov  rax, rdx
    jmp  90f
73: mov  eax, dword ptr [r11 + r10*4]    # skip[folded c]  (zero-extends into rax)
    add  r14, rax
    jmp  71b
10: cmp  byte ptr [rip + use_avx2], 0
    je   12f
    # ==== AVX2 two-byte prefilter (32 bytes / iteration) ====
    vpbroadcastb ymm4, byte ptr [rip + pa0]
    vpbroadcastb ymm5, byte ptr [rip + pa1]
    vpbroadcastb ymm6, byte ptr [rip + pb0]
    vpbroadcastb ymm7, byte ptr [rip + pb1]
    mov  r14, r12
11: lea  rax, [r14 + 32]
    add  rax, [rip + dd]
    cmp  rax, r13
    ja   60f                  # tail (epilogue does vzeroupper)
    vmovdqu ymm0, [r14]
    vpcmpeqb ymm1, ymm0, ymm4
    vpcmpeqb ymm2, ymm0, ymm5
    vpor  ymm1, ymm1, ymm2    # A matches
    mov   rax, r14
    add   rax, [rip + dd]
    vmovdqu ymm0, [rax]
    vpcmpeqb ymm2, ymm0, ymm6
    vpcmpeqb ymm3, ymm0, ymm7
    vpor  ymm2, ymm2, ymm3    # B matches
    vpand ymm1, ymm1, ymm2
    vpmovmskb eax, ymm1
    test  eax, eax
    jz    15f
    mov   r15d, eax
13: bsf   ecx, r15d
    lea   rax, [r14 + rcx]
    sub   rax, [rip + off_a]
    cmp   rax, r12
    jb    14f
    mov   rdx, rax
    add   rdx, [rip + pat_len]
    cmp   rdx, r13
    ja    80f
    mov   rdi, rax
    push  rax
    call  verify
    pop   rdx
    test  al, al
    jz    14f
    mov   rax, rdx
    jmp   90f
14: lea   rax, [r15 - 1]
    and   r15, rax
    jnz   13b
15: add   r14, 32
    jmp   11b
    # ==== SSE2 two-byte prefilter (16 bytes / iteration) ====
12: movzx eax, byte ptr [rip + pa0]
    imul  eax, eax, 0x01010101
    movd  xmm4, eax
    pshufd xmm4, xmm4, 0
    movzx eax, byte ptr [rip + pa1]
    imul  eax, eax, 0x01010101
    movd  xmm5, eax
    pshufd xmm5, xmm5, 0
    movzx eax, byte ptr [rip + pb0]
    imul  eax, eax, 0x01010101
    movd  xmm6, eax
    pshufd xmm6, xmm6, 0
    movzx eax, byte ptr [rip + pb1]
    imul  eax, eax, 0x01010101
    movd  xmm7, eax
    pshufd xmm7, xmm7, 0
    mov  r14, r12             # window pointer (A positions)
20: lea  rax, [r14 + 16]
    add  rax, [rip + dd]
    cmp  rax, r13
    ja   60f                  # not enough room for B window -> scalar tail
    movdqu xmm0, [r14]
    movdqa xmm1, xmm0
    pcmpeqb xmm0, xmm4
    pcmpeqb xmm1, xmm5
    por   xmm0, xmm1          # A matches
    mov   rax, r14
    add   rax, [rip + dd]
    movdqu xmm2, [rax]
    movdqa xmm3, xmm2
    pcmpeqb xmm2, xmm6
    pcmpeqb xmm3, xmm7
    por   xmm2, xmm3          # B matches
    pand  xmm0, xmm2
    pmovmskb eax, xmm0
    test  eax, eax
    jz    50f
    mov   r15d, eax           # candidate bitmask
30: bsf   ecx, r15d           # k
    lea   rax, [r14 + rcx]    # A position
    sub   rax, [rip + off_a]  # candidate start
    cmp   rax, r12
    jb    40f                 # before floor
    mov   rdx, rax
    add   rdx, [rip + pat_len]
    cmp   rdx, r13
    ja    80f                 # cannot fit -> no further matches
    mov   rdi, rax
    push  rax
    call  verify
    pop   rdx
    test  al, al
    jz    40f
    mov   rax, rdx
    jmp   90f
40: lea   rax, [r15 - 1]      # clear lowest set bit
    and   r15, rax
    jnz   30b
50: add   r14, 16
    jmp   20b
    # ---- scalar tail (stride-independent) ----
60: cmp   r14, r13
    jae   80f
    mov   al, [r14]
    cmp   al, [rip + pa0]
    je    61f
    cmp   al, [rip + pa1]
    jne   62f
61: mov   rax, r14
    sub   rax, [rip + off_a]
    cmp   rax, r12
    jb    62f
    mov   rdx, rax
    add   rdx, [rip + pat_len]
    cmp   rdx, r13
    ja    80f
    mov   rdi, rax
    push  rax
    call  verify
    pop   rdx
    test  al, al
    jz    62f
    mov   rax, rdx
    jmp   90f
62: inc   r14
    jmp   60b
80: xor   rax, rax
90: cmp   byte ptr [rip + use_avx2], 0
    je    91f
    vzeroupper                # drop dirty YMM state before any legacy SSE
91: pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret

# ----------------------------------------------------------------------------
# line_start(rdi=q, rsi=base) -> rax = start of q's line
# ----------------------------------------------------------------------------
line_start:
    mov  rax, rdi
1:  cmp  rax, rsi
    jbe  2f
    cmp  byte ptr [rax - 1], 0x0a
    je   2f
    dec  rax
    jmp  1b
2:  ret

# ----------------------------------------------------------------------------
# flush_out: write the output buffer to fd 1 and reset it
# ----------------------------------------------------------------------------
flush_out:                      # flush rbp's context buffer to fd 1 (locked)
    mov  rax, [rbp + CTX_OUTLEN]
    test rax, rax
    jz   9f
    call lock_acquire
    mov  rdi, 1
    lea  rsi, [rbp + CTX_OUTBUF]
    mov  rdx, [rbp + CTX_OUTLEN]
    mov  rax, SYS_write
    syscall
    call lock_release
    mov  qword ptr [rbp + CTX_OUTLEN], 0
9:  ret

# out_lock: spinlock so concurrent workers never interleave a write() syscall
lock_acquire:
1:  mov  eax, 1
    xchg eax, [rip + out_lock]
    test eax, eax
    jz   2f
    pause
    jmp  1b
2:  ret
lock_release:
    mov  dword ptr [rip + out_lock], 0
    ret

# ----------------------------------------------------------------------------
# print_line(rdi=line_ptr, rsi=line_len): record match + queue the line
# ----------------------------------------------------------------------------
# append_raw(rdi=src, rsi=len): copy into ctx buffer; caller guarantees room
append_raw:
    test rsi, rsi
    jz   9f
    mov  rcx, rsi
    mov  rdx, [rbp + CTX_OUTLEN]
    lea  rax, [rbp + CTX_OUTBUF]
    add  rax, rdx
    add  rdx, rcx
    mov  [rbp + CTX_OUTLEN], rdx
    mov  rsi, rdi
    mov  rdi, rax
    rep  movsb
9:  ret

# print_line emits the whole line (prefix+body+\n) as one atomic unit so a flush
# never splits a line across threads.
print_line:
    push r12
    push r13
    push r14
    mov  r12, rdi              # line ptr
    mov  r13, rsi              # line len
    mov  byte ptr [rip + match_found], 1
    lea  r14, [r13 + 1]        # total = body + '\n'
    cmp  byte ptr [rip + multi], 0
    je   1f
    add  r14, [rbp + CTX_CURPL]
    inc  r14                   # + path + ':'
1:  cmp  r14, OUTBUF_SZ
    ja   3f                    # line larger than buffer: stream under lock
    mov  rax, [rbp + CTX_OUTLEN]
    add  rax, r14
    cmp  rax, OUTBUF_SZ
    jbe  2f
    call flush_out             # flush at this (clean) line boundary
2:  cmp  byte ptr [rip + multi], 0
    je   21f
    mov  rdi, [rbp + CTX_CURPP]
    mov  rsi, [rbp + CTX_CURPL]
    call append_raw
    lea  rdi, [rip + colon]
    mov  rsi, 1
    call append_raw
21: mov  rdi, r12
    mov  rsi, r13
    call append_raw
    lea  rdi, [rip + newline]
    mov  rsi, 1
    call append_raw
    jmp  4f
3:  # oversized line: flush, then write the pieces under one held lock
    call flush_out
    call lock_acquire
    cmp  byte ptr [rip + multi], 0
    je   31f
    mov  rdi, 1
    mov  rsi, [rbp + CTX_CURPP]
    mov  rdx, [rbp + CTX_CURPL]
    mov  rax, SYS_write
    syscall
    mov  rdi, 1
    lea  rsi, [rip + colon]
    mov  rdx, 1
    mov  rax, SYS_write
    syscall
31: mov  rdi, 1
    mov  rsi, r12
    mov  rdx, r13
    mov  rax, SYS_write
    syscall
    mov  rdi, 1
    lea  rsi, [rip + newline]
    mov  rdx, 1
    mov  rax, SYS_write
    syscall
    call lock_release
4:  pop  r14
    pop  r13
    pop  r12
    ret

# ----------------------------------------------------------------------------
# search_file(rdi=path_ptr, rsi=path_len)
# ----------------------------------------------------------------------------
search_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov  [rbp + CTX_CURPP], rdi
    mov  [rbp + CTX_CURPL], rsi
    mov  rsi, O_RDONLY
    xor  rdx, rdx
    mov  rax, SYS_open
    syscall
    test rax, rax
    js   70f
    mov  r14, rax              # fd
    # ---- read() into the per-thread buffer: no fstat/mmap for small files ----
    lea  rsi, [rbp + CTX_READBUF]
    mov  rdi, r14
    mov  rdx, READBUF_SZ
    mov  rax, SYS_read
    syscall
    test rax, rax
    js   60f                   # read error -> close
    cmp  rax, READBUF_SZ
    jae  14f                   # buffer full -> large file -> mmap fallback
    test rax, rax
    jz   50f                   # empty file -> close
    mov  r13, rax              # size (regular file shorter than buffer = whole file)
    mov  rdi, r14
    mov  rax, SYS_close
    syscall
    lea  r12, [rbp + CTX_READBUF]   # base
    lea  r15, [r12 + r13]           # end
    push 0                     # did_mmap = 0
    jmp  10f
14: # ---- large file: fstat + mmap (rare) ----
    mov  rdi, r14
    lea  rsi, [rbp + CTX_STAT]
    mov  rax, SYS_fstat
    syscall
    test rax, rax
    js   60f
    mov  r13, [rbp + CTX_STAT + STAT_SIZE]
    test r13, r13
    jz   50f
    xor  rdi, rdi
    mov  rsi, r13
    mov  rdx, PROT_READ
    mov  r10, MAP_PRIVATE
    mov  r8,  r14
    xor  r9,  r9
    mov  rax, SYS_mmap
    syscall
    test rax, rax
    js   60f
    mov  r12, rax              # base
    mov  rdi, r14
    mov  rax, SYS_close
    syscall
    lea  r15, [r12 + r13]      # end
    push 1                     # did_mmap = 1
10: # ---- binary check: NUL in first BIN_PEEK bytes? ----
    mov  rsi, r12
    add  rsi, BIN_PEEK
    cmp  rsi, r15
    jbe  11f
    mov  rsi, r15
11: mov  rdi, r12
    xor  edx, edx
    call memchr_b
    test rax, rax
    jnz  40f                   # binary -> skip
    # ---- search ----
    cmp  qword ptr [rip + pat_len], 0
    je   20f                   # empty pattern -> every line
    mov  rbx, r12              # cur
12: mov  rdi, rbx
    mov  rsi, r15
    call find_match
    test rax, rax
    jz   40f
    mov  rdi, rax
    mov  rsi, r12
    push rax
    call line_start
    mov  r14, rax              # line start
    pop  rax
    mov  rdi, rax
    mov  rsi, r15
    mov  edx, 0x0a
    call memchr_b              # newline after match
    test rax, rax
    jnz  13f
    mov  rax, r15              # last line: ends at EOF
13: mov  rbx, rax              # le
    mov  rdi, r14
    mov  rsi, rbx
    sub  rsi, r14
    call print_line
    lea  rbx, [rbx + 1]        # cur = le + 1
    cmp  rbx, r15
    jb   12b
    jmp  40f
    # ---- empty pattern: emit every line ----
20: mov  rbx, r12
21: cmp  rbx, r15
    jae  40f
    mov  rdi, rbx
    mov  rsi, r15
    mov  edx, 0x0a
    call memchr_b
    test rax, rax
    jnz  22f
    mov  rdi, rbx
    mov  rsi, r15
    sub  rsi, rbx
    call print_line
    jmp  40f
22: mov  r14, rax              # le
    mov  rdi, rbx
    mov  rsi, r14
    sub  rsi, rbx
    call print_line
    lea  rbx, [r14 + 1]
    jmp  21b
40: pop  rax                   # did_mmap (pushed before the binary check)
    test rax, rax
    jz   80f                   # read path: nothing to unmap
    mov  rdi, r12
    mov  rsi, r13
    mov  rax, SYS_munmap
    syscall
    jmp  80f
50: mov  rdi, r14
    mov  rax, SYS_close
    syscall
    jmp  80f
60: mov  rdi, r14
    mov  rax, SYS_close
    syscall
70: mov  byte ptr [rip + had_error], 1
80: pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

# ----------------------------------------------------------------------------
# arena_alloc(rdi=need) -> rax = slot pointer (or 0 if arena exhausted)
# Lock-free bump allocation via lock xadd.
# ----------------------------------------------------------------------------
arena_alloc:
    mov  rax, rdi
    lock xadd [rip + arena_next], rax   # rax = old arena_next
    mov  rdx, rax
    add  rdx, rdi
    lea  rcx, [rip + arena]
    add  rcx, ARENA_SZ
    cmp  rdx, rcx
    ja   9f
    ret
9:  xor  rax, rax
    ret

# dirq_push(rdi=ptr): push a directory pointer; bump `pending` on success
dirq_push:
    push rdi
1:  mov  eax, 1
    xchg eax, [rip + dirq_lock]
    test eax, eax
    jnz  1b
    pop  rdi
    mov  rax, [rip + dirq_top]
    cmp  rax, MAX_DIRS
    jae  2f
    lea  rcx, [rip + dirq]
    mov  [rcx + rax*8], rdi
    inc  rax
    mov  [rip + dirq_top], rax
    lock inc qword ptr [rip + pending]
2:  mov  dword ptr [rip + dirq_lock], 0
    ret

# dirq_pop() -> rax = directory pointer, or 0 if queue empty
dirq_pop:
1:  mov  eax, 1
    xchg eax, [rip + dirq_lock]
    test eax, eax
    jnz  1b
    mov  rax, [rip + dirq_top]
    test rax, rax
    jz   2f
    dec  rax
    mov  [rip + dirq_top], rax
    lea  rcx, [rip + dirq]
    mov  rax, [rcx + rax*8]
    jmp  3f
2:  xor  rax, rax
3:  mov  dword ptr [rip + dirq_lock], 0
    ret

# ----------------------------------------------------------------------------
# enqueue_dir(rdi=path_ptr, rsi=len): copy path into arena, push to queue
# ----------------------------------------------------------------------------
enqueue_dir:
    push rbx
    push r12
    mov  rbx, rdi
    mov  r12, rsi
    lea  rdi, [r12 + 1]
    call arena_alloc
    test rax, rax
    jz   9f
    mov  rcx, r12
    mov  rsi, rbx
    mov  rdi, rax
    push rax
    rep  movsb
    mov  byte ptr [rdi], 0
    pop  rdi                   # slot ptr
    call dirq_push
9:  pop  r12
    pop  rbx
    ret

# ----------------------------------------------------------------------------
# traverse(rdi=dir_path_ptr): read one directory; search files, queue subdirs.
# rbp = this worker's context. Non-recursive (subdirs go on the queue).
# Uses d_type so most entries need no stat.
# ----------------------------------------------------------------------------
traverse:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub  rsp, PATHBUF_SZ + DIRENT_BUFSZ + 16
    mov  r13, rsp                          # local path buffer
    lea  r14, [rsp + PATHBUF_SZ]           # local dirent buffer
    # copy dir path into local pathbuf, measure length -> r12
    mov  rsi, rdi
    mov  rdi, r13
    xor  r12, r12
.Lt_cpy:
    mov  al, [rsi + r12]
    mov  [rdi + r12], al
    test al, al
    jz   .Lt_open
    inc  r12
    jmp  .Lt_cpy
.Lt_open:
    mov  rdi, r13
    mov  rsi, O_RDONLY | O_DIRECTORY
    xor  rdx, rdx
    mov  rax, SYS_open
    syscall
    test rax, rax
    js   .Lt_done
    mov  r15, rax                          # dirfd
.Lt_refill:
    mov  rdi, r15
    mov  rsi, r14
    mov  rdx, DIRENT_BUFSZ
    mov  rax, SYS_getdents64
    syscall
    test rax, rax
    jle  .Lt_close
    lea  rcx, [r14 + rax]
    mov  [rsp + PATHBUF_SZ + DIRENT_BUFSZ], rcx   # dirent end
    mov  rbx, r14                          # cursor
.Lt_entry:
    lea  rcx, [rbx + 19]                   # name
    cmp  byte ptr [rcx], '.'
    jne  .Lt_use
    cmp  byte ptr [rcx + 1], 0
    je   .Lt_next
    cmp  byte ptr [rcx + 1], '.'
    jne  .Lt_use
    cmp  byte ptr [rcx + 2], 0
    je   .Lt_next
.Lt_use:
    cmp  byte ptr [rbx + 18], DT_LNK
    je   .Lt_next
    cmp  r12, PATH_MAX_BUILD
    jae  .Lt_next
    # build child path = pathbuf[base_len] '/' name
    lea  rdi, [r13 + r12]
    mov  byte ptr [rdi], '/'
    inc  rdi
    lea  rsi, [rbx + 19]
.Lt_cp:
    mov  al, [rsi]
    mov  [rdi], al
    inc  rsi
    inc  rdi
    test al, al
    jnz  .Lt_cp
    mov  rsi, rdi
    sub  rsi, r13
    dec  rsi                               # child length
    movzx eax, byte ptr [rbx + 18]         # d_type
    cmp  al, DT_DIR
    je   .Lt_dir
    cmp  al, DT_REG
    je   .Lt_reg
    cmp  al, DT_UNKNOWN
    je   .Lt_unknown
    jmp  .Lt_next
.Lt_dir:
    cmp  byte ptr [rip + opt_r], 0
    je   .Lt_next
    mov  rdi, r13
    call enqueue_dir
    jmp  .Lt_next
.Lt_reg:
    mov  rdi, r13
    call search_file
    jmp  .Lt_next
.Lt_unknown:
    push rsi                               # save child length
    mov  rdi, AT_FDCWD
    mov  rsi, r13
    lea  rdx, [rbp + CTX_STAT]
    xor  r10, r10
    mov  rax, SYS_newfstatat
    syscall
    pop  rsi
    test rax, rax
    js   .Lt_next
    mov  eax, [rbp + CTX_STAT + STAT_MODE]
    and  eax, S_IFMT
    cmp  eax, S_IFDIR
    je   .Lt_udir
    cmp  eax, S_IFREG
    je   .Lt_ureg
    jmp  .Lt_next
.Lt_udir:
    cmp  byte ptr [rip + opt_r], 0
    je   .Lt_next
    mov  rdi, r13
    call enqueue_dir
    jmp  .Lt_next
.Lt_ureg:
    mov  rdi, r13
    call search_file
.Lt_next:
    movzx rax, word ptr [rbx + 16]         # d_reclen
    add  rbx, rax
    cmp  rbx, [rsp + PATHBUF_SZ + DIRENT_BUFSZ]
    jb   .Lt_entry
    jmp  .Lt_refill
.Lt_close:
    mov  rdi, r15
    mov  rax, SYS_close
    syscall
.Lt_done:
    add  rsp, PATHBUF_SZ + DIRENT_BUFSZ + 16
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

# ----------------------------------------------------------------------------
# handle_root(rdi=path_ptr, rsi=len): a command-line argument. rbp = ctx[0].
# File -> search directly; directory -> enqueue for the parallel walk.
# ----------------------------------------------------------------------------
handle_root:
    push rbx
    push r12
    mov  rbx, rdi
    mov  r12, rsi
    mov  rdi, AT_FDCWD
    mov  rsi, rbx
    lea  rdx, [rip + statbuf]
    xor  r10, r10
    mov  rax, SYS_newfstatat
    syscall
    test rax, rax
    js   3f
    mov  eax, [rip + statbuf + STAT_MODE]
    and  eax, S_IFMT
    cmp  eax, S_IFDIR
    je   1f
    cmp  eax, S_IFREG
    je   2f
    jmp  4f
1:  cmp  byte ptr [rip + opt_r], 0
    je   4f
    mov  rdi, rbx
    mov  rsi, r12
    call enqueue_dir
    jmp  4f
2:  mov  rdi, rbx
    mov  rsi, r12
    call search_file
    jmp  4f
3:  mov  byte ptr [rip + had_error], 1
4:  pop  r12
    pop  rbx
    ret

# ----------------------------------------------------------------------------
# prep_pattern: build comparison pattern, fold flag, and choose rare pivot byte
# ----------------------------------------------------------------------------
prep_pattern:
    push rbx
    mov  r8, [rip + pat_len]
    test r8, r8
    jz   90f                   # empty pattern: scanner special-cases it
    # ---- build comparison pattern + fold flag ----
    cmp  byte ptr [rip + opt_i], 0
    jne  2f
    mov  rax, [rip + pat_ptr]
    mov  [rip + pat_cmp_ptr], rax
    mov  byte ptr [rip + fold_flag], 0
    jmp  4f
2:  mov  byte ptr [rip + fold_flag], 1
    lea  rax, [rip + pat_lower]
    mov  [rip + pat_cmp_ptr], rax
    mov  rsi, [rip + pat_ptr]
    lea  rdi, [rip + pat_lower]
    xor  rcx, rcx
3:  cmp  rcx, r8
    jae  4f
    mov  al, [rsi + rcx]
    cmp  al, 'A'
    jb   31f
    cmp  al, 'Z'
    ja   31f
    add  al, 0x20
31: mov  [rdi + rcx], al
    inc  rcx
    jmp  3b
    # ---- pass 1: off_a = argmin rank ----
4:  mov  r9, [rip + pat_cmp_ptr]
    lea  r10, [rip + freq_tab]
    xor  rcx, rcx
    xor  r11, r11
    mov  bl, 0xff
5:  cmp  rcx, r8
    jae  6f
    movzx eax, byte ptr [r9 + rcx]
    movzx eax, byte ptr [r10 + rax]
    cmp  al, bl
    jae  51f
    mov  bl, al
    mov  r11, rcx
51: inc  rcx
    jmp  5b
6:  mov  [rip + off_a], r11
    mov  [rip + off_b], r11    # default (1-char patterns)
    # rank of A (bl) decides single vs two-byte; long patterns override to BMH
    mov  byte ptr [rip + scan_mode], 0
    cmp  bl, 64
    ja   61f
    mov  byte ptr [rip + scan_mode], 1
61: cmp  r8, 1
    je   8f
    # ---- pass 2: off_b = argmin rank over offsets != off_a ----
    xor  rcx, rcx
    xor  r11, r11
    mov  bl, 0xff
    mov  r10, [rip + off_a]
7:  cmp  rcx, r8
    jae  71f
    cmp  rcx, r10
    je   70f                   # skip off_a
    mov  rax, [rip + pat_cmp_ptr]
    movzx eax, byte ptr [rax + rcx]
    lea  rdx, [rip + freq_tab]
    movzx eax, byte ptr [rdx + rax]
    cmp  al, bl
    jae  70f
    mov  bl, al
    mov  r11, rcx
70: inc  rcx
    jmp  7b
71: mov  [rip + off_b], r11
    # ---- order so off_a < off_b ----
    mov  rax, [rip + off_a]
    mov  rdx, [rip + off_b]
    cmp  rax, rdx
    jbe  8f
    mov  [rip + off_a], rdx
    mov  [rip + off_b], rax
8:  # ---- dd, and the A/B bytes (+ alternate case for -i) ----
    mov  rax, [rip + off_b]
    sub  rax, [rip + off_a]
    mov  [rip + dd], rax
    mov  r9, [rip + pat_cmp_ptr]
    mov  r10, [rip + off_a]
    movzx eax, byte ptr [r9 + r10]
    mov  [rip + pa0], al
    mov  [rip + pa1], al
    cmp  byte ptr [rip + opt_i], 0
    je   81f
    cmp  al, 'a'
    jb   81f
    cmp  al, 'z'
    ja   81f
    sub  al, 0x20
    mov  [rip + pa1], al
81: mov  r9, [rip + pat_cmp_ptr]
    mov  r10, [rip + off_b]
    movzx eax, byte ptr [r9 + r10]
    mov  [rip + pb0], al
    mov  [rip + pb1], al
    cmp  byte ptr [rip + opt_i], 0
    je   85f
    cmp  al, 'a'
    jb   85f
    cmp  al, 'z'
    ja   85f
    sub  al, 0x20
    mov  [rip + pb1], al
85: # ---- long patterns: switch to Boyer-Moore-Horspool, build skip table ----
    mov  rax, [rip + pat_len]
    cmp  rax, BMH_MIN
    jb   90f
    mov  byte ptr [rip + scan_mode], 2
    lea  rdi, [rip + skip_tab]
    mov  ecx, 256
    rep  stosd                 # skip[*] = m  (eax = pat_len)
    mov  r9, [rip + pat_cmp_ptr]
    lea  r10, [rip + skip_tab]
    mov  r8, [rip + pat_len]
    dec  r8                     # m-1
    xor  rcx, rcx
86: cmp  rcx, r8               # for i in 0 .. m-2
    jae  90f
    movzx edx, byte ptr [r9 + rcx]
    mov  eax, r8d
    sub  eax, ecx              # skip[pat[i]] = (m-1) - i
    mov  [r10 + rdx*4], eax
    inc  rcx
    jmp  86b
90: pop  rbx
    ret

# ----------------------------------------------------------------------------
# worker(rbp=ctx): pop directories off the shared queue and traverse them.
# Exits when the queue is empty AND no directory is still being processed.
# ----------------------------------------------------------------------------
worker:
    push rbx
.Lw_loop:
    mov  rax, [rip + dirq_top]  # cheap unlocked peek (test-and-test-and-set)
    test rax, rax
    jz   .Lw_empty
    call dirq_pop
    test rax, rax
    jz   .Lw_empty
    mov  rdi, rax
    call traverse
    lock dec qword ptr [rip + pending]
    jmp  .Lw_loop
.Lw_empty:
    mov  rax, [rip + pending]
    test rax, rax
    jz   .Lw_done
    pause
    jmp  .Lw_loop
.Lw_done:
    call flush_out             # flush this context under the output lock
    pop  rbx
    ret

# ----------------------------------------------------------------------------
# run_search: drain the directory queue. The main thread walks alone until
# enough subdirectories accumulate to be worth parallelizing (so small trees
# never pay thread-spawn cost), then spawns helpers and joins as a worker.
# Output order is unspecified across files when parallel (like ripgrep).
# ----------------------------------------------------------------------------
run_search:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    # ---- thread count = popcount(cpu affinity mask), capped ----
    xor  edi, edi
    mov  esi, 128
    lea  rdx, [rip + cpumask]
    mov  rax, SYS_sched_getaffinity
    syscall
    test rax, rax
    jg   .Lrs_pc
    mov  rax, 8                 # fallback if the syscall fails
.Lrs_pc:
    add  rax, 7
    shr  rax, 3                 # qwords in mask
    mov  rcx, rax
    lea  rsi, [rip + cpumask]
    xor  r12, r12
.Lrs_pcl:
    test rcx, rcx
    jz   .Lrs_pcd
    mov  rax, [rsi]
    popcnt rax, rax
    add  r12, rax
    add  rsi, 8
    dec  rcx
    jmp  .Lrs_pcl
.Lrs_pcd:
    test r12, r12
    jnz  .Lrs_cap
    mov  r12, 1
.Lrs_cap:
    cmp  r12, MAX_THREADS
    jbe  .Lrs_prime
    mov  r12, MAX_THREADS
.Lrs_prime:
    lea  rbp, [rip + ctxs]              # main thread = ctx[0]
.Lrs_ploop:
    mov  rax, [rip + pending]
    test rax, rax
    jz   .Lrs_flush                     # finished while walking alone
    cmp  r12, 1
    jbe  .Lrs_solodir                   # single core: stay solo
    mov  rax, [rip + dirq_top]
    cmp  rax, PAR_SPAWN
    jae  .Lrs_spawn                     # enough parallel work -> spawn
.Lrs_solodir:
    call dirq_pop
    test rax, rax
    jz   .Lrs_pwait
    mov  rdi, rax
    call traverse
    lock dec qword ptr [rip + pending]
    jmp  .Lrs_ploop
.Lrs_pwait:
    mov  rax, [rip + pending]
    test rax, rax
    jz   .Lrs_flush
    pause
    jmp  .Lrs_ploop
.Lrs_flush:
    call flush_out
    jmp  .Lrs_done
    # ---- spawn helpers 1 .. n-1, main joins as a worker ----
.Lrs_spawn:
    mov  r13, 1
.Lrs_sloop:
    cmp  r13, r12
    jae  .Lrs_main
    xor  rdi, rdi
    mov  rsi, THREAD_STACK
    mov  rdx, PROT_RW
    mov  r10, MAP_ANON_PRIV
    mov  r8, -1
    xor  r9, r9
    mov  rax, SYS_mmap_n
    syscall
    test rax, rax
    js   .Lrs_spawnstop
    lea  r14, [rax + THREAD_STACK]
    mov  rax, r13
    imul rax, rax, CTX_SIZE
    lea  r15, [rip + ctxs]
    add  r15, rax              # r15 = &ctx[i] (inherited by child)
    mov  rdi, THREAD_FLAGS
    mov  rsi, r14
    xor  rdx, rdx
    lea  r10, [rip + tids]
    lea  rax, [r13*4]
    add  r10, rax              # &tids[i]
    xor  r8, r8
    mov  rax, SYS_clone
    syscall
    test rax, rax
    jz   .Lrs_child
    inc  r13
    jmp  .Lrs_sloop
.Lrs_spawnstop:
    mov  r12, r13              # fewer threads than planned
.Lrs_main:
    lea  rbp, [rip + ctxs]
    call worker
    mov  r13, 1
.Lrs_join:
    cmp  r13, r12
    jae  .Lrs_done
    lea  r14, [rip + tids]
    lea  rax, [r13*4]
    add  r14, rax
.Lrs_jw:
    mov  eax, [r14]
    test eax, eax
    jz   .Lrs_jnext
    mov  rdi, r14
    mov  esi, FUTEX_WAIT
    mov  edx, eax
    xor  r10, r10
    xor  r8, r8
    xor  r9, r9
    mov  rax, SYS_futex
    syscall
    jmp  .Lrs_jw
.Lrs_jnext:
    inc  r13
    jmp  .Lrs_join
.Lrs_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbp
    pop  rbx
    ret
.Lrs_child:
    mov  rbp, r15
    call worker
    xor  rdi, rdi
    mov  rax, SYS_exit
    syscall

# ----------------------------------------------------------------------------
# usage_exit: print usage to stderr, exit 2
# ----------------------------------------------------------------------------
usage_exit:
    mov  rdi, 2
    lea  rsi, [rip + usage]
    mov  rdx, usage_end - usage
    mov  rax, SYS_write
    syscall
    mov  rdi, 2
    mov  rax, SYS_exit
    syscall

# ----------------------------------------------------------------------------
# _start
# ----------------------------------------------------------------------------
_start:
    # ---- detect AVX2 (CPUID leaf1 OSXSAVE+AVX, XGETBV, leaf7 AVX2) ----
    mov  eax, 1
    cpuid
    mov  r8d, ecx
    and  r8d, 0x18000000       # bit27 OSXSAVE | bit28 AVX
    cmp  r8d, 0x18000000
    jne  1f
    xor  ecx, ecx
    xgetbv
    and  eax, 6                # XCR0 bit1 (SSE) | bit2 (YMM)
    cmp  eax, 6
    jne  1f
    mov  eax, 7
    xor  ecx, ecx
    cpuid
    test ebx, 0x20             # leaf7 EBX bit5 = AVX2
    jz   1f
    mov  byte ptr [rip + use_avx2], 1
1:  mov  r12, [rsp]            # argc
    lea  rbx, [rsp + 8]        # argv

    # ---- pass 1: classify ----
    mov  r13, 1
    xor  r14, r14
    xor  r15, r15             # npaths
10: cmp  r13, r12
    jae  20f
    mov  rax, [rbx + r13*8]
    test r14, r14
    jnz  16f
    cmp  byte ptr [rax], '-'
    jne  16f
    cmp  byte ptr [rax + 1], 0
    je   16f
    cmp  byte ptr [rax + 1], '-'
    jne  12f
    cmp  byte ptr [rax + 2], 0
    jne  12f
    mov  r14, 1
    jmp  19f
12: lea  rcx, [rax + 1]
13: mov  dl, [rcx]
    test dl, dl
    jz   19f
    cmp  dl, 'i'
    jne  14f
    mov  byte ptr [rip + opt_i], 1
    jmp  15f
14: cmp  dl, 'r'
    jne  18f
    mov  byte ptr [rip + opt_r], 1
15: inc  rcx
    jmp  13b
16: cmp  qword ptr [rip + pat_ptr], 0
    jne  17f
    mov  [rip + pat_ptr], rax
    mov  rdi, rax
    call strlen
    mov  [rip + pat_len], rax
    jmp  19f
17: inc  r15
    jmp  19f
18: jmp  usage_exit
19: inc  r13
    jmp  10b
20: cmp  qword ptr [rip + pat_ptr], 0
    je   usage_exit
    test r15, r15
    jz   usage_exit
    cmp  byte ptr [rip + opt_r], 0
    jne  21f
    cmp  r15, 1
    jbe  22f
21: mov  byte ptr [rip + multi], 1
22: call prep_pattern
    lea  rax, [rip + arena]
    mov  [rip + arena_next], rax
    lea  rbp, [rip + ctxs]            # root files searched into ctx[0]

    # ---- pass 2: handle each path argument (file -> search, dir -> enqueue) ----
    mov  r13, 1
    xor  r14, r14
    xor  r15, r15             # pattern_seen
30: cmp  r13, r12
    jae  40f
    mov  rax, [rbx + r13*8]
    test r14, r14
    jnz  34f
    cmp  byte ptr [rax], '-'
    jne  34f
    cmp  byte ptr [rax + 1], 0
    je   34f
    cmp  byte ptr [rax + 1], '-'
    jne  39f
    cmp  byte ptr [rax + 2], 0
    jne  39f
    mov  r14, 1
    jmp  39f
34: test r15, r15
    jnz  35f
    mov  r15, 1
    jmp  39f
35: mov  rdi, rax
    push rax
    call strlen
    mov  rsi, rax
    pop  rdi
    call handle_root
39: inc  r13
    jmp  30b
40: call run_search           # search collected files (parallel if large)
    cmp  byte ptr [rip + had_error], 0
    jne  43f
    cmp  byte ptr [rip + match_found], 0
    jne  42f
    mov  rdi, 1
    jmp  44f
42: xor  rdi, rdi
    jmp  44f
43: mov  rdi, 2
44: mov  rax, SYS_exit
    syscall
