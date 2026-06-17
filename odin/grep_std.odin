// odingrep_std - idiomatic Odin, single-threaded: recursive walk via
// os.read_all_directory + os.lstat (regular files only, no symlink follow),
// os.read_entire_file + bytes.index. Stdlib all the way.
package main

import "core:bufio"
import "core:bytes"
import "core:io"
import "core:os"

g_pat: []byte
g_lpat: []byte
g_ci: bool
g_recursive: bool
g_multi: bool
g_matched: bool
g_out: bufio.Writer
g_lowbuf: [dynamic]byte // reused ASCII-lowercase scratch

// ASCII-only, length-preserving lowercase (matches grep -iF; NOT Unicode,
// which would shift byte offsets).
ascii_lower :: proc(dst, src: []byte) {
	for b, i in src {
		if b >= 'A' && b <= 'Z' {
			dst[i] = b + 32
		} else {
			dst[i] = b
		}
	}
}

search_file :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data, context.allocator)

	peek := len(data)
	if peek > 65536 {
		peek = 65536
	}
	if bytes.index_byte(data[:peek], 0) >= 0 {
		return // binary
	}

	hay := data
	needle := g_pat
	if g_ci {
		if cap(g_lowbuf) < len(data) {
			resize(&g_lowbuf, len(data))
		}
		lb := g_lowbuf[:len(data)]
		ascii_lower(lb, data)
		hay = lb
		needle = g_lpat
	}

	pos := 0
	for pos < len(hay) { // < not <= : empty-pattern fix (see spec)
		i := bytes.index(hay[pos:], needle)
		if i < 0 {
			break
		}
		m := pos + i
		ls := bytes.last_index_byte(data[:m], '\n') + 1 // -1+1 == 0 if none
		le := len(data)
		if j := bytes.index_byte(data[m:], '\n'); j >= 0 {
			le = m + j
		}
		g_matched = true
		if g_multi {
			bufio.writer_write_string(&g_out, path)
			bufio.writer_write_byte(&g_out, ':')
		}
		bufio.writer_write(&g_out, data[ls:le])
		bufio.writer_write_byte(&g_out, '\n')
		pos = le + 1
	}
}

// Join root + "/" + name, matching how grep prints recursive paths
// (relative to the command-line argument, not an absolute fullpath):
// trailing slashes are collapsed and a "." (or empty) root is dropped.
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

// Recursive walk: regular files only, do not follow symlinks (use lstat).
walk :: proc(dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	for fi in infos {
		full := join_path(dir, fi.name)
		// re-lstat so symlinks are classified as symlinks (not followed).
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
			search_file(full)
			delete(full)
		case:
			delete(full)
		}
	}
}

usage :: proc() -> ! {
	os.write_string(os.stderr, "usage: odingrep [-r] [-i] PATTERN PATH...\n")
	os.exit(2)
}

main :: proc() {
	paths: [dynamic]string
	pat_set := false
	no_more := false
	args := os.args
	for a in args[1:] {
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

	buf: [65536]byte
	w, _ := io.to_writer(os.to_stream(os.stdout))
	bufio.writer_init_with_buf(&g_out, w, buf[:])

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
			search_file(p)
		}
	}

	bufio.writer_flush(&g_out)
	if g_matched {
		os.exit(0)
	}
	os.exit(1)
}
