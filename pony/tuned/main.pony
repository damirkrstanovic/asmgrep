"""
ponygrep_std_mt_tuned - the MEMORY pillar mapped onto Pony's per-actor heaps.
Same actor pool as _mt, but each Worker OWNS and REUSES one mutable
`Array[U8] ref` read buffer that lives in its per-actor heap. The buffer grows to
the largest file the worker sees and is never freed between files. Each file is
read via direct libc FFI (@open/@read/@lseek/@close) straight into that reused
buffer -- the stdlib File.read always allocates a fresh iso array, which is
exactly the per-file allocation we are trying to avoid. A 64KB prefix is read
first and binary-checked; the rest is read only if the prefix is clean. Matched
lines are copied into small fresh `val` arrays to hand to the Writer, so the
reused `ref` buffer never escapes the actor (Pony's data-race guarantee holds).

Default uses every Pony scheduler (all cores). Pin with --ponythreads=N.
"""
use "files"
use "runtime_info"

use @open[I32](path: Pointer[U8] tag, flags: I32)
use @read[ISize](fd: I32, buffer: Pointer[U8] tag, len: USize)
use @lseek[I64](fd: I32, offset: I64, whence: I32)
use @close[I32](fd: I32)

actor Writer
  let _out: OutStream
  var _buf: Array[U8] iso = recover Array[U8](1 << 16) end

  new create(out: OutStream) =>
    _out = out

  be line(data: Array[U8] val) =>
    _buf.append(data)

  be finish(main: Main) =>
    let b = _buf = recover Array[U8] end
    _out.write(consume b)
    main.writer_done()

actor Worker
  let _writer: Writer
  let _main: Main
  let _pat: Array[U8] val
  let _ci: Bool
  let _multi: Bool
  // The reused per-actor read buffer. Grown to the largest file, never freed.
  let _buf: Array[U8] ref = Array[U8]

  new create(writer: Writer, main: Main, pat: Array[U8] val,
    ci: Bool, multi: Bool)
  =>
    _writer = writer
    _main = main
    _pat = pat
    _ci = ci
    _multi = multi

  be scan(paths: Array[String] val) =>
    var matched = false
    for p in paths.values() do
      if scan_one(p) then matched = true end
    end
    _main.worker_done(matched)

  // Read file p into the reused buffer (prefix-first binary check), search it,
  // copy any matching lines out to the Writer. Returns true if any match.
  fun ref scan_one(p: String val): Bool =>
    let fd = @open(p.cstring(), I32(0)) // O_RDONLY
    if fd < 0 then return false end

    // total size via lseek(END) then back to start
    let sz = @lseek(fd, I64(0), I32(2)).usize()
    @lseek(fd, I64(0), I32(0))
    if sz == 0 then @close(fd); return false end

    // read a prefix first, binary-check it, then read the rest only if clean.
    // undefined() reserves (geometric grow, realloc preserves prior bytes) and
    // sets the logical size; we then truncate to what @read actually returned.
    let peek = if sz < 65536 then sz else USize(65536) end
    _buf.undefined[U8](peek)
    let got_prefix = @read(fd, _buf.cpointer(), peek)
    if got_prefix <= 0 then @close(fd); return false end
    var got = got_prefix.usize()
    _buf.truncate(got)
    if is_binary_prefix(got) then @close(fd); return false end

    if sz > got then
      _buf.undefined[U8](sz)
      while got < sz do
        let n = @read(fd, _buf.cpointer(got), sz - got)
        if n <= 0 then break end
        got = got + n.usize()
      end
      _buf.truncate(got)
    end
    @close(fd)

    search(p)

  // NUL byte anywhere in the (already-read) prefix => binary.
  fun ref is_binary_prefix(n: USize): Bool =>
    var i: USize = 0
    while i < n do
      try if _buf(i)? == 0 then return true end end
      i = i + 1
    end
    false

  fun lower(b: U8): U8 =>
    if (b >= 0x41) and (b <= 0x5A) then b + 0x20 else b end

  fun ref find(start: USize): ISize =>
    let n = _buf.size()
    let m = _pat.size()
    if m == 0 then return start.isize() end
    if (start + m) > n then return -1 end
    var i = start
    let last = (n - m) + 1
    while i < last do
      var j: USize = 0
      var ok = true
      while j < m do
        var hb = try _buf(i + j)? else 0 end
        var pb = try _pat(j)? else 0 end
        if _ci then hb = lower(hb); pb = lower(pb) end
        if hb != pb then ok = false; break end
        j = j + 1
      end
      if ok then return i.isize() end
      i = i + 1
    end
    -1

  // Search the reused buffer; copy each matching line into a fresh val array
  // (with optional path prefix) and send it to the Writer. The ref buffer never
  // leaves this actor.
  fun ref search(p: String val): Bool =>
    let n = _buf.size()
    var pos: USize = 0
    var matched = false
    while pos < n do
      let h = find(pos)
      if h < 0 then break end
      let m = h.usize()
      var ls = m
      while (ls > 0) and (try _buf(ls - 1)? != '\n' else false end) do
        ls = ls - 1
      end
      var le = m
      while (le < n) and (try _buf(le)? != '\n' else false end) do
        le = le + 1
      end
      matched = true
      let out = recover iso Array[U8]((le - ls) + p.size() + 2) end
      if _multi then
        out.append(p)
        out.push(':')
      end
      // copy the matched line byte-by-byte (each read is a U8 val) so the ref
      // buffer is never passed across the actor boundary
      var c = ls
      while c < le do
        out.push(try _buf(c)? else 0 end)
        c = c + 1
      end
      out.push('\n')
      _writer.line(consume out)
      pos = le + 1
      if le >= n then break end
    end
    matched

primitive Args
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
      if (not no_more) and (a.size() > 1) and (try a(0)? == '-' else false end)
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
  let _auth: FileAuth
  var _ci: Bool = false
  var _recurse: Bool = false
  var _multi: Bool = false
  var _pat: Array[U8] val = recover Array[U8] end
  var _matched: Bool = false
  var _pending: USize = 0

  new create(env: Env) =>
    _env = env
    _writer = Writer(env.out)
    _auth = FileAuth(env.root)

    match Args(env.args)
    | (let ci: Bool, let r: Bool, let pat: String, let paths: Array[String] val) =>
      _ci = ci
      _recurse = r
      _pat = pat.array()
      _multi = r or (paths.size() > 1)
      dispatch(paths)
    else
      env.err.print("usage: ponygrep_std_mt_tuned [-r] [-i] PATTERN PATH...")
      env.exitcode(2)
    end

  fun ref dispatch(paths: Array[String] val) =>
    let files = Array[String]
    for p in paths.values() do
      let fp = FilePath(_auth, p)
      try
        let info = FileInfo(fp)?
        if info.directory then
          if _recurse then collect(fp, files) end
        elseif info.file then
          files.push(fp.path)
        end
      end
    end
    let frozen = recover iso Array[String](files.size()) end
    for f in files.values() do frozen.push(f) end
    let files': Array[String] val = consume frozen

    let n = files'.size()
    if n == 0 then
      _writer.finish(this)
      return
    end

    var nw = Scheduler.schedulers(SchedulerInfoAuth(_env.root)).usize()
    if nw < 1 then nw = 1 end
    if nw > n then nw = n end
    _pending = nw

    let base = n / nw
    let extra = n % nw
    var start: USize = 0
    var w: USize = 0
    while w < nw do
      let len = base + (if w < extra then USize(1) else USize(0) end)
      let chunk = recover iso Array[String](len) end
      var k: USize = 0
      while k < len do
        try chunk.push(files'(start + k)?) end
        k = k + 1
      end
      start = start + len
      let worker = Worker(_writer, this, _pat, _ci, _multi)
      worker.scan(consume chunk)
      w = w + 1
    end

  fun ref collect(dir: FilePath, files: Array[String] ref) =>
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
            collect(child, files)
          elseif info.file then
            files.push(child.path)
          end
        end
      end
    end

  be worker_done(matched: Bool) =>
    if matched then _matched = true end
    _pending = _pending - 1
    if _pending == 0 then
      _writer.finish(this)
    end

  be writer_done() =>
    if not _matched then _env.exitcode(1) end
