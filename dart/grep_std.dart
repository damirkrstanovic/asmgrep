// dartgrep_std - idiomatic single-threaded Dart (AOT-compiled native).
// Mirrors python/grep_std.py: whole-file read + byte-level literal scan +
// NUL-in-first-64KB binary skip. Operates on raw bytes (Uint8List), never
// String, to stay byte-for-byte identical to `grep -F`.
//
// Build: dart compile exe dart/grep_std.dart -o bin/dartgrep_std
//
// Concurrency follow-up: Dart isolates could parallelise the recursive walk
// (one isolate per subtree); shipping _std (single-threaded) only for now.

import 'dart:io';
import 'dart:typed_data';

const int NL = 0x0A; // '\n'
const int COLON = 0x3A; // ':'

// ASCII-lowercase a byte in place (0x41..0x5A -> +0x20).
int _lower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;

// Byte-level substring search: index of `needle` in `hay` at or after `from`,
// or -1. `hay`/`needle` are assumed already case-folded by the caller if -i.
int _find(Uint8List hay, Uint8List needle, int from) {
  final n = hay.length;
  final m = needle.length;
  if (m == 0) return from <= n ? from : -1; // empty needle matches at `from`
  if (m > n) return -1;
  final last = n - m;
  final first = needle[0];
  for (int i = from; i <= last; i++) {
    if (hay[i] != first) continue;
    int j = 1;
    while (j < m && hay[i + j] == needle[j]) j++;
    if (j == m) return i;
  }
  return -1;
}

// rindex of `b` in hay[0..end), or -1.
int _rfind(Uint8List hay, int b, int end) {
  for (int i = end - 1; i >= 0; i--) {
    if (hay[i] == b) return i;
  }
  return -1;
}

// index of `b` in hay at or after `from`, or -1.
int _indexByte(Uint8List hay, int b, int from) {
  final n = hay.length;
  for (int i = from; i < n; i++) {
    if (hay[i] == b) return i;
  }
  return -1;
}

bool searchFile(String path, Uint8List pat, Uint8List lpat, bool ci, bool multi,
    BytesBuilder out) {
  Uint8List data;
  try {
    data = File(path).readAsBytesSync();
  } catch (_) {
    return false;
  }
  final n = data.length;
  if (n == 0) return false;

  // Binary skip: any NUL in first 64KB.
  final peek = n < 65536 ? n : 65536;
  for (int i = 0; i < peek; i++) {
    if (data[i] == 0) return false;
  }

  final Uint8List hay;
  final Uint8List needle;
  if (ci) {
    hay = Uint8List(n);
    for (int i = 0; i < n; i++) hay[i] = _lower(data[i]);
    needle = lpat;
  } else {
    hay = data;
    needle = pat;
  }

  final pathBytes = multi ? _osBytes(path) : null;
  bool matched = false;
  int pos = 0;
  while (pos <= n) {
    final m = _find(hay, needle, pos);
    if (m < 0) break;
    // phantom empty line after a trailing newline: grep emits no line there.
    if (m == n && n > 0 && data[n - 1] == NL) break;
    final ls = _rfind(data, NL, m) + 1; // prev '\n'+1 (or 0)
    int le = _indexByte(data, NL, m);
    if (le < 0) le = n;
    matched = true;
    if (multi) {
      out.add(pathBytes!);
      out.addByte(COLON);
    }
    out.add(Uint8List.view(data.buffer, data.offsetInBytes + ls, le - ls));
    out.addByte(NL);
    pos = le + 1;
  }
  return matched;
}

// Encode a path string to the bytes the OS uses. Dart gives us paths as
// Strings; re-encode as UTF-8 to emit. (Fixtures are ASCII, so exact.)
Uint8List _osBytes(String s) {
  // Fast path: pure ASCII.
  bool ascii = true;
  for (int i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7F) {
      ascii = false;
      break;
    }
  }
  if (ascii) {
    final b = Uint8List(s.length);
    for (int i = 0; i < s.length; i++) b[i] = s.codeUnitAt(i);
    return b;
  }
  return Uint8List.fromList(s.codeUnits.isEmpty ? const [] : _utf8(s));
}

List<int> _utf8(String s) => s.runes.fold<List<int>>([], (acc, r) {
      if (r < 0x80) {
        acc.add(r);
      } else if (r < 0x800) {
        acc.add(0xC0 | (r >> 6));
        acc.add(0x80 | (r & 0x3F));
      } else if (r < 0x10000) {
        acc.add(0xE0 | (r >> 12));
        acc.add(0x80 | ((r >> 6) & 0x3F));
        acc.add(0x80 | (r & 0x3F));
      } else {
        acc.add(0xF0 | (r >> 18));
        acc.add(0x80 | ((r >> 12) & 0x3F));
        acc.add(0x80 | ((r >> 6) & 0x3F));
        acc.add(0x80 | (r & 0x3F));
      }
      return acc;
    });

// Recursive walk: skip symlinks, recurse subdirs, search regular files.
bool walk(String root, Uint8List pat, Uint8List lpat, bool ci, bool multi,
    BytesBuilder out) {
  bool matched = false;
  final stack = <String>[root];
  while (stack.isNotEmpty) {
    final d = stack.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = Directory(d).listSync(recursive: false, followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      final p = e.path;
      try {
        if (FileSystemEntity.isLinkSync(p)) continue; // don't follow symlinks
        if (FileSystemEntity.isDirectorySync(p)) {
          stack.add(p);
        } else if (FileSystemEntity.isFileSync(p)) {
          if (searchFile(p, pat, lpat, ci, multi, out)) matched = true;
        }
      } catch (_) {
        continue;
      }
    }
  }
  return matched;
}

int run(List<String> args) {
  bool ci = false, r = false, noMore = false;
  String? pat;
  final paths = <String>[];

  for (final a in args) {
    if (!noMore && a.startsWith('-') && a != '-') {
      if (a == '--') {
        noMore = true;
        continue;
      }
      for (int i = 1; i < a.length; i++) {
        final q = a[i];
        if (q == 'i') {
          ci = true;
        } else if (q == 'r') {
          r = true;
        } else {
          stderr.write('usage: dartgrep_std [-r] [-i] PATTERN PATH...\n');
          return 2;
        }
      }
    } else if (pat == null) {
      pat = a;
    } else {
      paths.add(a);
    }
  }

  if (pat == null || paths.isEmpty) {
    stderr.write('usage: dartgrep_std [-r] [-i] PATTERN PATH...\n');
    return 2;
  }

  final patb = _osBytes(pat);
  final lpat = Uint8List(patb.length);
  for (int i = 0; i < patb.length; i++) lpat[i] = _lower(patb[i]);
  final multi = r || paths.length > 1;

  final out = BytesBuilder(copy: false);
  bool matched = false;

  for (final p in paths) {
    FileSystemEntityType t;
    try {
      // FOLLOW symlinks at top level.
      t = FileSystemEntity.typeSync(p, followLinks: true);
    } catch (_) {
      continue;
    }
    if (t == FileSystemEntityType.directory) {
      if (r && walk(p, patb, lpat, ci, multi, out)) matched = true;
    } else if (t == FileSystemEntityType.file) {
      if (searchFile(p, patb, lpat, ci, multi, out)) matched = true;
    }
  }

  if (out.length > 0) stdout.add(out.takeBytes());
  return matched ? 0 : 1;
}

void main(List<String> args) {
  exit(run(args));
}
