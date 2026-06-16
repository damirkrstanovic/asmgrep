// gogrep - idiomatic Go: filepath.WalkDir + os.ReadFile + bytes.Index.
// Single-threaded, stdlib all the way (no hand-rolled syscalls/SIMD/threads).
package main

import (
	"bufio"
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
)

var (
	pat       []byte
	lpat      []byte
	patSet    bool
	ci        bool
	recursive bool
	multi     bool
	matched   bool
	out       *bufio.Writer
	lowbuf    []byte // reused ASCII-lowercase scratch
)

// ASCII-only, length-preserving lowercase (matches grep -iF; unlike the
// Unicode-aware bytes.ToLower, which would shift byte offsets).
func asciiLower(dst, src []byte) {
	for i, b := range src {
		if b >= 'A' && b <= 'Z' {
			dst[i] = b + 32
		} else {
			dst[i] = b
		}
	}
}

func searchFile(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	peek := len(data)
	if peek > 65536 {
		peek = 65536
	}
	if bytes.IndexByte(data[:peek], 0) >= 0 {
		return // binary
	}
	hay := data
	needle := pat
	if ci {
		if cap(lowbuf) < len(data) {
			lowbuf = make([]byte, len(data))
		}
		lowbuf = lowbuf[:len(data)]
		asciiLower(lowbuf, data)
		hay = lowbuf
		needle = lpat
	}
	pos := 0
	for pos <= len(hay) {
		i := bytes.Index(hay[pos:], needle)
		if i < 0 {
			break
		}
		m := pos + i
		ls := bytes.LastIndexByte(data[:m], '\n') + 1
		le := len(data)
		if j := bytes.IndexByte(data[m:], '\n'); j >= 0 {
			le = m + j
		}
		matched = true
		if multi {
			out.WriteString(path)
			out.WriteByte(':')
		}
		out.Write(data[ls:le])
		out.WriteByte('\n')
		pos = le + 1
	}
}

func usage() {
	os.Stderr.WriteString("usage: gogrep [-r] [-i] PATTERN PATH...\n")
	os.Exit(2)
}

func main() {
	var paths []string
	noMore := false
	for _, a := range os.Args[1:] {
		if !noMore && len(a) >= 2 && a[0] == '-' {
			if a == "--" {
				noMore = true
				continue
			}
			for _, c := range a[1:] {
				switch c {
				case 'i':
					ci = true
				case 'r':
					recursive = true
				default:
					usage()
				}
			}
		} else if !patSet {
			pat = []byte(a)
			patSet = true
		} else {
			paths = append(paths, a)
		}
	}
	if !patSet || len(paths) == 0 {
		usage()
	}
	lpat = make([]byte, len(pat))
	asciiLower(lpat, pat)
	multi = recursive || len(paths) > 1
	out = bufio.NewWriterSize(os.Stdout, 1<<16)

	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.IsDir() {
			if recursive {
				filepath.WalkDir(p, func(path string, d fs.DirEntry, err error) error {
					if err != nil {
						return nil
					}
					if !d.IsDir() && d.Type().IsRegular() {
						searchFile(path)
					}
					return nil
				})
			}
		} else {
			searchFile(p)
		}
	}
	out.Flush()
	if matched {
		os.Exit(0)
	}
	os.Exit(1)
}
