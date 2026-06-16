// gogrep_mt - idiomatic concurrent Go: filepath.WalkDir + os.ReadFile +
// bytes.Index, parallelized with a goroutine worker pool (the natural Go idiom).
package main

import (
	"bufio"
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
)

var (
	pat       []byte
	lpat      []byte
	patSet    bool
	ci        bool
	recursive bool
	multi     bool
)

func asciiLower(dst, src []byte) {
	for i, b := range src {
		if b >= 'A' && b <= 'Z' {
			dst[i] = b + 32
		} else {
			dst[i] = b
		}
	}
}

func searchFile(path string, w *bytes.Buffer, rbuf *[]byte, lowbuf *[]byte) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.Size() <= 0 {
		return false
	}
	size := int(fi.Size())
	peek := size
	if peek > 65536 {
		peek = 65536
	}
	if cap(*rbuf) < peek {
		*rbuf = make([]byte, peek)
	}
	pbuf := (*rbuf)[:peek]
	if _, err := io.ReadFull(f, pbuf); err != nil {
		return false
	}
	if bytes.IndexByte(pbuf, 0) >= 0 {
		return false // binary: rest unread, no huge allocation
	}
	data := pbuf
	if size > peek {
		if cap(*rbuf) < size {
			nb := make([]byte, size)
			copy(nb, pbuf)
			*rbuf = nb
		}
		data = (*rbuf)[:size]
		if _, err := io.ReadFull(f, data[peek:]); err != nil {
			return false
		}
	}
	hay := data
	needle := pat
	if ci {
		if cap(*lowbuf) < len(data) {
			*lowbuf = make([]byte, len(data))
		}
		*lowbuf = (*lowbuf)[:len(data)]
		asciiLower(*lowbuf, data)
		hay = *lowbuf
		needle = lpat
	}
	found := false
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
		found = true
		if multi {
			w.WriteString(path)
			w.WriteByte(':')
		}
		w.Write(data[ls:le])
		w.WriteByte('\n')
		pos = le + 1
	}
	return found
}

func usage() {
	os.Stderr.WriteString("usage: gogrep_mt [-r] [-i] PATTERN PATH...\n")
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

	var files []string
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.IsDir() {
			if recursive {
				filepath.WalkDir(p, func(path string, d fs.DirEntry, err error) error {
					if err == nil && !d.IsDir() && d.Type().IsRegular() {
						files = append(files, path)
					}
					return nil
				})
			}
		} else {
			files = append(files, p)
		}
	}

	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	var mu sync.Mutex
	var idx int64
	var anyMatch int32
	var wg sync.WaitGroup
	for t := 0; t < runtime.NumCPU(); t++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var buf bytes.Buffer
			var rbuf []byte
			var lowbuf []byte
			for {
				i := int(atomic.AddInt64(&idx, 1)) - 1
				if i >= len(files) {
					break
				}
				buf.Reset()
				if searchFile(files[i], &buf, &rbuf, &lowbuf) {
					atomic.StoreInt32(&anyMatch, 1)
				}
				if buf.Len() > 0 {
					mu.Lock()
					out.Write(buf.Bytes())
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()
	out.Flush()
	if atomic.LoadInt32(&anyMatch) == 1 {
		os.Exit(0)
	}
	os.Exit(1)
}
