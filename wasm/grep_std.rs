// wasmgrep_std - Rust compiled to wasm32-wasip1, run under wasmtime.
// Single-threaded literal grep clone. Mirrors python/grep_std.py byte-for-byte.
// std only: std::fs, std::env, std::io, std::process.

use std::env;
use std::fs;
use std::io::{self, Write};
use std::process::exit;

// 256-byte ASCII-lowercase translation table.
fn lower_byte(c: u8) -> u8 {
    if (0x41..=0x5A).contains(&c) {
        c + 0x20
    } else {
        c
    }
}

fn lower_bytes(b: &[u8]) -> Vec<u8> {
    b.iter().map(|&c| lower_byte(c)).collect()
}

// substring search: find `needle` in `hay` starting at `from`.
fn find_from(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    let n = hay.len();
    let m = needle.len();
    if from > n {
        return None;
    }
    if m == 0 {
        return Some(from); // empty needle matches at `from`
    }
    if m > n {
        return None;
    }
    let last = n - m;
    let first = needle[0];
    let mut i = from;
    while i <= last {
        if hay[i] == first && &hay[i..i + m] == needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn rfind_nl(data: &[u8], end: usize) -> Option<usize> {
    // last index of b'\n' in data[0..end]
    data[..end].iter().rposition(|&c| c == 0x0A)
}

fn find_nl(data: &[u8], from: usize) -> Option<usize> {
    data[from..]
        .iter()
        .position(|&c| c == 0x0A)
        .map(|p| p + from)
}

fn search_file(
    path: &str,
    pat: &[u8],
    lpat: &[u8],
    ci: bool,
    multi: bool,
    out: &mut Vec<u8>,
) -> bool {
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(_) => return false,
    };
    if data.is_empty() {
        return false;
    }
    let peek = &data[..data.len().min(65536)];
    if peek.contains(&0x00) {
        return false; // binary skip
    }

    let hay_owned;
    let hay: &[u8];
    let needle: &[u8];
    if ci {
        hay_owned = lower_bytes(&data);
        hay = &hay_owned;
        needle = lpat;
    } else {
        hay = &data;
        needle = pat;
    }

    let mut matched = false;
    let mut pos = 0usize;
    let n = data.len();
    while pos <= n {
        let m = match find_from(hay, needle, pos) {
            Some(m) => m,
            None => break,
        };
        // phantom empty line after a trailing newline
        if m == n && n > 0 && data[n - 1] == 0x0A {
            break;
        }
        let ls = match rfind_nl(&data, m) {
            Some(idx) => idx + 1,
            None => 0,
        };
        let le = find_nl(&data, m).unwrap_or(n);
        matched = true;
        if multi {
            out.extend_from_slice(path.as_bytes());
            out.push(b':');
        }
        out.extend_from_slice(&data[ls..le]);
        out.push(b'\n');
        pos = le + 1;
    }
    matched
}

fn is_symlink(path: &str) -> bool {
    match fs::symlink_metadata(path) {
        Ok(md) => md.file_type().is_symlink(),
        Err(_) => false,
    }
}

fn walk(
    path: &str,
    pat: &[u8],
    lpat: &[u8],
    ci: bool,
    multi: bool,
    out: &mut Vec<u8>,
) -> bool {
    let mut matched = false;
    let mut stack: Vec<String> = vec![path.to_string()];
    while let Some(d) = stack.pop() {
        let rd = match fs::read_dir(&d) {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        for entry in rd {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let p = entry.path();
            let ps = match p.to_str() {
                Some(s) => s.to_string(),
                None => continue,
            };
            // skip symlinks (don't follow)
            if is_symlink(&ps) {
                continue;
            }
            let md = match fs::metadata(&ps) {
                Ok(md) => md,
                Err(_) => continue,
            };
            if md.is_dir() {
                stack.push(ps);
            } else if md.is_file() {
                if search_file(&ps, pat, lpat, ci, multi, out) {
                    matched = true;
                }
            }
        }
    }
    matched
}

fn usage_exit() -> ! {
    eprintln!("usage: wasmgrep_std [-r] [-i] PATTERN PATH...");
    exit(2);
}

fn main() {
    let argv: Vec<String> = env::args().collect();
    let mut ci = false;
    let mut r = false;
    let mut pat: Option<String> = None;
    let mut paths: Vec<String> = Vec::new();
    let mut no_more = false;

    // wasmtime forwards the `--` separator (from the launcher) to the guest as
    // argv[1]; drop exactly that leading separator before normal parsing so the
    // real CLI contract (`PROG [-r] [-i] [--] PATTERN PATH...`) is honored.
    let mut rest = &argv[1..];
    if rest.first().map(|s| s.as_str()) == Some("--") {
        rest = &rest[1..];
    }

    for a in rest.iter() {
        if !no_more && a.starts_with('-') && a != "-" {
            if a == "--" {
                no_more = true;
                continue;
            }
            for q in a[1..].chars() {
                match q {
                    'i' => ci = true,
                    'r' => r = true,
                    _ => usage_exit(),
                }
            }
        } else if pat.is_none() {
            pat = Some(a.clone());
        } else {
            paths.push(a.clone());
        }
    }

    let pat = match pat {
        Some(p) => p,
        None => usage_exit(),
    };
    if paths.is_empty() {
        usage_exit();
    }

    let patb = pat.into_bytes();
    let lpat = lower_bytes(&patb);
    let multi = r || paths.len() > 1;

    let mut out: Vec<u8> = Vec::new();
    let mut matched = false;
    for p in &paths {
        // stat following symlinks
        let md = match fs::metadata(p) {
            Ok(md) => md,
            Err(_) => continue,
        };
        if md.is_dir() {
            if r && walk(p, &patb, &lpat, ci, multi, &mut out) {
                matched = true;
            }
        } else if md.is_file() {
            if search_file(p, &patb, &lpat, ci, multi, &mut out) {
                matched = true;
            }
        }
    }

    let stdout = io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(&out);
    let _ = lock.flush();

    exit(if matched { 0 } else { 1 });
}
