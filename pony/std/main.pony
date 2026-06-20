"""
ponygrep_std - single-threaded idiomatic Pony: walk + whole-file read + byte
substring search. All scanning happens in Main; one Writer actor serializes
output. Run with --ponythreads=1 for a true serial baseline (the work is not
distributed across actors here regardless).
"""
use "files"

actor Writer
  """
  Single output sink. Buffers matched lines into one Array[U8] and writes them to
  stdout in one shot at the end, so nothing interleaves and we pay one syscall.
  """
  let _out: OutStream
  var _buf: Array[U8] iso = recover Array[U8](1 << 16) end

  new create(out: OutStream) =>
    _out = out

  be line(prefix: (String val | None), data: Array[U8] val, ls: USize, le: USize) =>
    match prefix
    | let p: String val =>
      _buf.append(p)
      _buf.push(':')
    end
    _buf.copy_from(data, ls, _buf.size(), le - ls)
    _buf.push('\n')

  be finish() =>
    let b = _buf = recover Array[U8] end
    _out.write(consume b)

primitive Scan
  """
  Byte-oriented literal substring search, grep -F parity. No regex.
  """
  fun lower(b: U8): U8 =>
    if (b >= 0x41) and (b <= 0x5A) then b + 0x20 else b end

  fun is_binary(data: Array[U8] val): Bool =>
    // NUL byte in the first 64KB => treat as binary, skip.
    let n = if data.size() < 65536 then data.size() else USize(65536) end
    var i: USize = 0
    while i < n do
      try if data(i)? == 0 then return true end end
      i = i + 1
    end
    false

  // Find needle in data[start..size). Returns offset or -1. ci => ASCII fold.
  fun find(data: Array[U8] val, start: USize, pat: Array[U8] val, ci: Bool): ISize =>
    let n = data.size()
    let m = pat.size()
    if m == 0 then return start.isize() end
    if (start + m) > n then return -1 end
    var i = start
    let last = (n - m) + 1
    while i < last do
      var j: USize = 0
      var ok = true
      while j < m do
        var hb = try data(i + j)? else 0 end
        var pb = try pat(j)? else 0 end
        if ci then hb = lower(hb); pb = lower(pb) end
        if hb != pb then ok = false; break end
        j = j + 1
      end
      if ok then return i.isize() end
      i = i + 1
    end
    -1

  // Scan one file's bytes, emitting each matching line once. Returns true if any
  // match was found.
  fun search(
    writer: Writer, prefix: (String val | None),
    data: Array[U8] val, pat: Array[U8] val, ci: Bool): Bool
  =>
    if is_binary(data) then return false end
    let n = data.size()
    var pos: USize = 0
    var matched = false
    while pos < n do
      let h = find(data, pos, pat, ci)
      if h < 0 then break end
      let m = h.usize()
      // line start: back up to char after previous newline
      var ls = m
      while (ls > 0) and (try data(ls - 1)? != '\n' else false end) do
        ls = ls - 1
      end
      // line end: forward to next newline
      var le = m
      while (le < n) and (try data(le)? != '\n' else false end) do
        le = le + 1
      end
      matched = true
      writer.line(prefix, data, ls, le)
      pos = le + 1
      if le >= n then break end
    end
    matched

primitive Args
  """
  Parse our args out of env.args, tolerating Pony runtime flags (which the
  runtime already consumes before env.args). Returns (ci, recurse, pat, paths)
  or None on usage error.
  """
  fun apply(args: Array[String] val)
    : ((Bool, Bool, String, Array[String] val) | None)
  =>
    var ci = false
    var r = false
    var no_more = false
    var pat: (String | None) = None
    let paths = recover trn Array[String] end
    var i: USize = 1
    while i < args.size() do
      let a = try args(i)? else "" end
      if (not no_more) and (a.size() >= 1) and (try a(0)? == '-' else false end)
        and (a.size() > 1)
      then
        if a == "--" then
          no_more = true
        else
          var k: USize = 1
          var bad = false
          while k < a.size() do
            match try a(k)? else 0 end
            | 'i' => ci = true
            | 'r' => r = true
            else bad = true
            end
            k = k + 1
          end
          if bad then return None end
        end
      else
        match pat
        | None => pat = a
        else paths.push(a)
        end
      end
      i = i + 1
    end
    match pat
    | let p: String =>
      if paths.size() == 0 then return None end
      (ci, r, p, consume paths)
    else
      None
    end

actor Main
  let _env: Env
  let _writer: Writer
  var _ci: Bool = false
  var _recurse: Bool = false
  var _multi: Bool = false
  var _pat: Array[U8] val = recover Array[U8] end
  var _matched: Bool = false

  new create(env: Env) =>
    _env = env
    _writer = Writer(env.out)

    match Args(env.args)
    | (let ci: Bool, let r: Bool, let pat: String, let paths: Array[String] val) =>
      _ci = ci
      _recurse = r
      _pat = pat.array()
      _multi = r or (paths.size() > 1)
      run(paths)
    else
      env.err.print("usage: ponygrep_std [-r] [-i] PATTERN PATH...")
      env.exitcode(2)
    end

  fun ref run(paths: Array[String] val) =>
    let auth = FileAuth(_env.root)
    for p in paths.values() do
      let fp = FilePath(auth, p)
      try
        let info = FileInfo(fp)?
        if info.directory then
          if _recurse then walk(fp) end
        elseif info.file then
          scan_path(fp)
        end
      end
    end
    _writer.finish()
    if not _matched then _env.exitcode(1) end

  fun ref walk(dir: FilePath) =>
    try
      let d = Directory(dir)?
      let entries: Array[String] ref = d.entries()?
      for e in entries.values() do
        try
          let child = dir.join(e)?
          let info = FileInfo(child)?
          if info.symlink then
            continue
          elseif info.directory then
            walk(child)
          elseif info.file then
            scan_path(child)
          end
        end
      end
    end

  fun ref scan_path(fp: FilePath) =>
    let prefix: (String val | None) = if _multi then fp.path else None end
    let data: Array[U8] val =
      match OpenFile(fp)
      | let f: File =>
        let sz = f.size()
        recover val f.read(sz) end
      else
        return
      end
    if Scan.search(_writer, prefix, data, _pat, _ci) then
      _matched = true
    end
