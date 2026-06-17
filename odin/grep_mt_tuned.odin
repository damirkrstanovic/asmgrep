// odingrep_std_mt_tuned - idiomatic Odin, tuned multithreaded.
// Pillars combined: parallelism + buffer reuse + prefix binary-check.
//  - single-threaded recursive walk collects the file list
//  - worker pool over the file list
//  - each worker reuses ONE growable read buffer (and one lowercase buffer)
//    across files (no per-file alloc in the steady state)
//  - read only a 64 KB prefix first, NUL-check it, and read the rest of the
//    file ONLY if the prefix passed (a huge binary blob is skipped after 64 KB
//    instead of being faulted in entirely)
//  - per-file output blocks serialized under a mutex
package main

import "core:bufio"
import "core:bytes"
import "core:io"
import "core:os"
import "core:sync"
import "core:thread"

PREFIX :: 65536

g_pat: []byte
g_lpat: []byte
g_ci: bool
g_recursive: bool
g_multi: bool

g_files: [dynamic]string

Shared :: struct {
	idx:     int,
	out:     bufio.Writer,
	outlock: sync.Mutex,
	matched: bool,
}

// Per-worker reusable scratch.
Worker_Ctx :: struct {
	sh:     ^Shared,
	rbuf:   [dynamic]byte, // reused read buffer
	lowbuf: [dynamic]byte, // reused ascii-lowercase scratch
	block:  [dynamic]byte, // reused per-file output block
}

ascii_lower :: proc(dst, src: []byte) {
	for b, i in src {
		if b >= 'A' && b <= 'Z' {
			dst[i] = b + 32
		} else {
			dst[i] = b
		}
	}
}

search_data :: proc(wc: ^Worker_Ctx, data: []byte, path: string) {
	// prefix already NUL-checked by caller; search the full data here.
	hay := data
	needle := g_pat
	if g_ci {
		if cap(wc.lowbuf) < len(data) {
			resize(&wc.lowbuf, len(data))
		}
		lb := wc.lowbuf[:len(data)]
		ascii_lower(lb, data)
		hay = lb
		needle = g_lpat
	}

	clear(&wc.block)
	any_match := false
	pos := 0
	for pos < len(hay) {
		i := bytes.index(hay[pos:], needle)
		if i < 0 {
			break
		}
		m := pos + i
		ls := bytes.last_index_byte(data[:m], '\n') + 1
		le := len(data)
		if j := bytes.index_byte(data[m:], '\n'); j >= 0 {
			le = m + j
		}
		any_match = true
		if g_multi {
			append(&wc.block, path)
			append(&wc.block, ':')
		}
		append(&wc.block, ..data[ls:le])
		append(&wc.block, '\n')
		pos = le + 1
	}

	if any_match {
		sync.atomic_store(&wc.sh.matched, true)
		sync.mutex_lock(&wc.sh.outlock)
		bufio.writer_write(&wc.sh.out, wc.block[:])
		sync.mutex_unlock(&wc.sh.outlock)
	}
}

// Read prefix into reused buffer, NUL-check, then read the rest only if it
// passed. Returns the full file contents as a slice into wc.rbuf.
process_file :: proc(wc: ^Worker_Ctx, path: string) {
	f, oerr := os.open(path)
	if oerr != nil {
		return
	}
	defer os.close(f)

	sz, serr := os.file_size(f)
	if serr != nil {
		return
	}
	size := int(sz)
	if size < 0 {
		return
	}

	// read the prefix (up to PREFIX bytes) into the reused buffer
	prefix_n := size
	if prefix_n > PREFIX {
		prefix_n = PREFIX
	}
	if cap(wc.rbuf) < max(size, prefix_n) {
		reserve(&wc.rbuf, max(size, 1))
	}
	resize(&wc.rbuf, prefix_n)
	got, rerr := os.read_full(f, wc.rbuf[:prefix_n])
	if rerr != nil && got == 0 {
		return
	}
	pn := got

	// binary check on the prefix BEFORE reading the rest
	if bytes.index_byte(wc.rbuf[:pn], 0) >= 0 {
		return // binary, skip without faulting in the whole file
	}

	if size > pn {
		// read the remainder into the (grown) buffer
		resize(&wc.rbuf, size)
		rest, _ := os.read_full(f, wc.rbuf[pn:size])
		total := pn + rest
		search_data(wc, wc.rbuf[:total], path)
	} else {
		search_data(wc, wc.rbuf[:pn], path)
	}
}

worker :: proc(t: ^thread.Thread) {
	wc := (^Worker_Ctx)(t.data)
	defer delete(wc.rbuf)
	defer delete(wc.lowbuf)
	defer delete(wc.block)
	for {
		i := sync.atomic_add(&wc.sh.idx, 1)
		if i >= len(g_files) {
			break
		}
		process_file(wc, g_files[i])
	}
}

// Join root + "/" + name, matching how grep prints recursive paths:
// trailing slashes collapsed and a "." (or empty) root dropped.
join_path :: proc(root, name: string) -> string {
	r := root
	for len(r) > 1 && r[len(r) - 1] == '/' {
		r = r[:len(r) - 1]
	}
	if r == "." || r == "" {
		b := make([]byte, len(name))
		copy(b, transmute([]byte)name)
		return string(b)
	}
	b := make([]byte, len(r) + 1 + len(name))
	copy(b, transmute([]byte)r)
	b[len(r)] = '/'
	copy(b[len(r) + 1:], transmute([]byte)name)
	return string(b)
}

walk :: proc(dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	for fi in infos {
		full := join_path(dir, fi.name)
		li, lerr := os.lstat(full, context.allocator)
		if lerr != nil {
			delete(full)
			continue
		}
		ty := li.type
		os.file_info_delete(li, context.allocator)
		#partial switch ty {
		case .Directory:
			walk(full)
			delete(full)
		case .Regular:
			append(&g_files, full) // ownership transferred to g_files
		case:
			delete(full)
		}
	}
}

clone_string :: proc(s: string) -> string {
	b := make([]byte, len(s))
	copy(b, transmute([]byte)s)
	return string(b)
}

usage :: proc() -> ! {
	os.write_string(os.stderr, "usage: odingrep [-r] [-i] PATTERN PATH...\n")
	os.exit(2)
}

main :: proc() {
	paths: [dynamic]string
	pat_set := false
	no_more := false
	for a in os.args[1:] {
		if !no_more && len(a) >= 2 && a[0] == '-' {
			if a == "--" {
				no_more = true
				continue
			}
			for c in transmute([]byte)a[1:] {
				switch c {
				case 'i':
					g_ci = true
				case 'r':
					g_recursive = true
				case:
					usage()
				}
			}
		} else if !pat_set {
			g_pat = transmute([]byte)a
			pat_set = true
		} else {
			append(&paths, a)
		}
	}
	if !pat_set || len(paths) == 0 {
		usage()
	}

	g_lpat = make([]byte, len(g_pat))
	ascii_lower(g_lpat, g_pat)
	g_multi = g_recursive || len(paths) > 1

	for p in paths {
		fi, err := os.stat(p, context.allocator)
		if err != nil {
			continue
		}
		is_dir := fi.type == .Directory
		os.file_info_delete(fi, context.allocator)
		if is_dir {
			if g_recursive {
				walk(p)
			}
		} else {
			append(&g_files, clone_string(p))
		}
	}

	sh: Shared
	buf: [65536]byte
	w, _ := io.to_writer(os.to_stream(os.stdout))
	bufio.writer_init_with_buf(&sh.out, w, buf[:])

	nt := os.get_processor_core_count()
	if nt < 1 {
		nt = 6
	}
	if nt > 64 {
		nt = 64
	}

	// per-worker contexts (stable storage, since worker holds a pointer)
	ctxs := make([]Worker_Ctx, nt)
	for i in 0 ..< nt {
		ctxs[i].sh = &sh
	}

	threads: [dynamic]^thread.Thread
	for i in 1 ..< nt {
		t := thread.create(worker)
		if t == nil {
			break
		}
		t.data = &ctxs[i]
		thread.start(t)
		append(&threads, t)
	}
	// main-thread worker uses ctxs[0]
	main_t := thread.Thread{}
	main_t.data = &ctxs[0]
	worker(&main_t)

	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	bufio.writer_flush(&sh.out)
	if sync.atomic_load(&sh.matched) {
		os.exit(0)
	}
	os.exit(1)
}
