// rustgrep - idiomatic Rust: the canonical grep stack — walkdir + rayon + memchr
// (the same crates ripgrep is built from). Naturally parallel (rayon), stdlib
// file reads, fast SIMD substring search via memchr::memmem.
use memchr::memmem;
use rayon::prelude::*;
use std::fs;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use walkdir::WalkDir;

fn usage() -> ! {
    eprintln!("usage: rustgrep [-r] [-i] PATTERN PATH...");
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (mut ci, mut recursive, mut no_more) = (false, false, false);
    let mut pat: Option<Vec<u8>> = None;
    let mut paths: Vec<String> = Vec::new();
    for a in &args[1..] {
        let b = a.as_bytes();
        if !no_more && b.len() >= 2 && b[0] == b'-' {
            if a == "--" {
                no_more = true;
                continue;
            }
            for &c in &b[1..] {
                match c {
                    b'i' => ci = true,
                    b'r' => recursive = true,
                    _ => usage(),
                }
            }
        } else if pat.is_none() {
            pat = Some(b.to_vec());
        } else {
            paths.push(a.clone());
        }
    }
    let pat = pat.unwrap_or_else(|| usage());
    if paths.is_empty() {
        usage();
    }
    let multi = recursive || paths.len() > 1;
    let lpat: Vec<u8> = pat.iter().map(|c| c.to_ascii_lowercase()).collect();
    let finder = memmem::Finder::new(if ci { &lpat } else { &pat });

    // collect the file list (stdlib walk)
    let mut files: Vec<String> = Vec::new();
    for p in &paths {
        match fs::metadata(p) {
            Ok(md) if md.is_dir() => {
                if recursive {
                    for e in WalkDir::new(p).into_iter().filter_map(|e| e.ok()) {
                        if e.file_type().is_file() {
                            files.push(e.path().to_string_lossy().into_owned());
                        }
                    }
                }
            }
            Ok(md) if md.is_file() => files.push(p.clone()),
            _ => {}
        }
    }

    let matched = AtomicBool::new(false);
    // parallel search (rayon). map_init gives each worker thread *reused* read and
    // lowercase buffers, so files don't allocate fresh pages on every read.
    let outputs: Vec<Vec<u8>> = files
        .par_iter()
        .map_init(
            || (Vec::<u8>::new(), Vec::<u8>::new()),
            |(rbuf, lbuf), path| {
                let mut out = Vec::new();
                rbuf.clear();
                let mut f = match fs::File::open(path) {
                    Ok(f) => f,
                    Err(_) => return out,
                };
                // read a prefix, check binary, read the rest only if not binary
                // (so a 291MB .git pack is skipped after 64KB, not read in full)
                if (&mut f).take(65536).read_to_end(rbuf).is_err() {
                    return out;
                }
                if memchr::memchr(0, rbuf).is_some() {
                    return out; // binary: rest unread
                }
                if rbuf.len() == 65536 && f.read_to_end(rbuf).is_err() {
                    return out;
                }
                let data: &[u8] = rbuf;
                let hay: &[u8] = if ci {
                    lbuf.clear();
                    lbuf.extend(data.iter().map(|c| c.to_ascii_lowercase()));
                    lbuf
                } else {
                    data
                };
                let mut pos = 0;
                while let Some(i) = finder.find(&hay[pos..]) {
                    let m = pos + i;
                    let ls = data[..m].iter().rposition(|&c| c == b'\n').map_or(0, |x| x + 1);
                    let le = memchr::memchr(b'\n', &data[m..]).map_or(data.len(), |x| m + x);
                    matched.store(true, Ordering::Relaxed);
                    if multi {
                        out.extend_from_slice(path.as_bytes());
                        out.push(b':');
                    }
                    out.extend_from_slice(&data[ls..le]);
                    out.push(b'\n');
                    pos = le + 1;
                    if pos > hay.len() {
                        break;
                    }
                }
                out
            },
        )
        .collect();

    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    for o in &outputs {
        let _ = lock.write_all(o);
    }
    let _ = lock.flush();
    std::process::exit(if matched.load(Ordering::Relaxed) { 0 } else { 1 });
}
