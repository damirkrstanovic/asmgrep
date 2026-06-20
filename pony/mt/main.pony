"""
ponygrep_std_mt - parallel via Pony ACTORS. Main collects the whole file list,
splits it into one chunk per scheduler, and hands each chunk to a Worker actor.
Workers scan concurrently (each reads its own files -> I/O is parallel too) and
send matched lines to a single Writer actor. Actors share no mutable state: the
paths are `String val` (immutable, shareable) and file contents are `Array[U8]
val`. Naive per-file allocation (fresh read every file).

Default uses every Pony scheduler (all cores). Pin with --ponythreads=N.
"""
use "files"
use "runtime_info"

actor Writer
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

  be finish(main: Main) =>
    let b = _buf = recover Array[U8] end
    _out.write(consume b)
    main.writer_done()

actor Worker
  let _writer: Writer
  let _main: Main
  let _auth: FileAuth
  let _pat: Array[U8] val
  let _ci: Bool
  let _multi: Bool

  new create(writer: Writer, main: Main, auth: FileAuth, pat: Array[U8] val,
    ci: Bool, multi: Bool)
  =>
    _writer = writer
    _main = main
    _auth = auth
    _pat = pat
    _ci = ci
    _multi = multi

  be scan(paths: Array[String] val) =>
    let auth = _auth
    var matched = false
    for p in paths.values() do
      let fp = FilePath(auth, p)
      let prefix: (String val | None) = if _multi then p else None end
      let data: Array[U8] val =
        match OpenFile(fp)
        | let f: File =>
          let sz = f.size()
          recover val f.read(sz) end
        else
          continue
        end
      if Scan.search(_writer, prefix, data, _pat, _ci) then
        matched = true
      end
    end
    _main.worker_done(matched)

primitive Scan
  fun lower(b: U8): U8 =>
    if (b >= 0x41) and (b <= 0x5A) then b + 0x20 else b end

  fun is_binary(data: Array[U8] val): Bool =>
    let n = if data.size() < 65536 then data.size() else USize(65536) end
    var i: USize = 0
    while i < n do
      try if data(i)? == 0 then return true end end
      i = i + 1
    end
    false

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
      var ls = m
      while (ls > 0) and (try data(ls - 1)? != '\n' else false end) do
        ls = ls - 1
      end
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
      env.err.print("usage: ponygrep_std_mt [-r] [-i] PATTERN PATH...")
      env.exitcode(2)
    end

  fun ref dispatch(paths: Array[String] val) =>
    // collect the full file list (sequential walk; the parallelism is the scan)
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
    // freeze the collected paths into a shareable val array (elements are
    // String val already; we just need the container to be val)
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

    // contiguous slices, one per worker
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
      let worker = Worker(_writer, this, _auth, _pat, _ci, _multi)
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
