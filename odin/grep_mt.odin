// odingrep_std_mt - idiomatic Odin, naive multithreaded: single-threaded
// recursive walk collects the file list, then a worker pool processes files.
// DELIBERATELY allocation-heavy: each file gets a FRESH full-size allocation
// (os.read_entire_file) and is read IN FULL before the binary check.
// Per-file output blocks are serialized under a mutex.
package main

import "core:bufio"
import "core:bytes"
import "core:io"
import "core:os"
import "core:sync"
import "core:thread"

g_pat: []byte
g_lpat: []byte
g_ci: bool
g_recursive: bool
g_multi: bool

g_files: [dynamic]string

Shared :: struct {
	idx:     int, // atomic file cursor
	out:     bufio.Writer,
	outlock: sync.Mutex,
	matched: bool, // atomic flag (0/1 via bool)
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

// Search already-loaded data, building this file's output block, then write it
// atomically under the mutex (per-file block is contiguous).
search_data :: proc(sh: ^Shared, data: []byte, path: string) {
	peek := len(data)
	if peek > 65536 {
		peek = 65536
	}
	if bytes.index_byte(data[:peek], 0) >= 0 {
		return // binary
	}

	hay := data
	needle := g_pat
	lowbuf: []byte
	if g_ci {
		lowbuf = make([]byte, len(data))
		ascii_lower(lowbuf, data)
		hay = lowbuf
		needle = g_lpat
	}
	defer if g_ci do delete(lowbuf)

	// collect this file's matches into a local block
	block: [dynamic]byte
	defer delete(block)
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
			append(&block, path)
			append(&block, ':')
		}
		append(&block, ..data[ls:le])
		append(&block, '\n')
		pos = le + 1
	}

	if any_match {
		sync.atomic_store(&sh.matched, true)
		sync.mutex_lock(&sh.outlock)
		bufio.writer_write(&sh.out, block[:])
		sync.mutex_unlock(&sh.outlock)
	}
}

worker :: proc(t: ^thread.Thread) {
	sh := (^Shared)(t.data)
	for {
		i := sync.atomic_add(&sh.idx, 1)
		if i >= len(g_files) {
			break
		}
		path := g_files[i]
		// Naive: fresh full-size allocation, whole file read before binary check.
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			continue
		}
		search_data(sh, data, path)
		delete(data, context.allocator)
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
		t := li.type
		os.file_info_delete(li, context.allocator)
		#partial switch t {
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

	threads: [dynamic]^thread.Thread
	for _ in 1 ..< nt {
		t := thread.create(worker)
		if t == nil {
			break
		}
		t.data = &sh
		thread.start(t)
		append(&threads, t)
	}
	// run one worker on the main thread too
	main_t := thread.Thread{}
	main_t.data = &sh
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
