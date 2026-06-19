# crgrep_std_mt_tuned - multithreaded Crystal + the memory pillar applied.
# Built with -Dpreview_mt (real OS threads via CRYSTAL_WORKERS).
# Each worker fiber owns ONE mutable Bytes read buffer (and one lowercase buffer,
# one output IO::Memory) and REUSES them across every file it processes -- Crystal
# Bytes are mutable, so the buffer-reuse pillar works (like D / OCaml). It reads a
# 64 KB PREFIX first, NUL-checks it, and reads the rest only if the prefix passed
# (so a huge binary .git pack is never fully faulted in then skipped).
# Mirrors c/grep_std_mt.c.

require "wait_group"

PREFIX = 65536

class Shared
  getter pat : Bytes
  getter lpat : Bytes
  getter ci : Bool
  getter multi : Bool
  getter files : Array(String)

  def initialize(pat_str : String, @ci : Bool, @multi : Bool, @files : Array(String))
    @pat = pat_str.to_slice.dup
    @lpat = ascii_lower_dup(@pat)
    @idx = Atomic(Int32).new(0)
    @matched = Atomic(Int32).new(0)
    @out_lock = Mutex.new
  end

  def next_index : Int32
    @idx.add(1)
  end

  def mark_match
    @matched.set(1)
  end

  def matched? : Bool
    @matched.get == 1
  end

  def emit(buf : IO::Memory)
    return if buf.bytesize == 0
    @out_lock.synchronize do
      STDOUT.write(buf.to_slice)
    end
    buf.clear
  end
end

def ascii_lower_dup(src : Bytes) : Bytes
  dst = src.dup
  dst.map! { |b| (b >= 'A'.ord && b <= 'Z'.ord) ? (b &+ 32_u8) : b }
  dst
end

def ascii_lower_into(dst : Bytes, src : Bytes, len : Int32) : Nil
  i = 0
  while i < len
    b = src[i]
    dst[i] = (b >= 'A'.ord && b <= 'Z'.ord) ? (b &+ 32_u8) : b
    i += 1
  end
end

# First index >= from where needle occurs in hay[0,len]; nil if none.
# Empty needle returns from. (Hand-rolled because Slice has no substring search;
# String#byte_index would force a String wrapper per scan over a reused buffer.)
def byte_index(hay : Bytes, len : Int32, needle : Bytes, from : Int32) : Int32?
  nlen = needle.size
  return from if nlen == 0
  return nil if from + nlen > len
  first = needle[0]
  last = len - nlen
  i = from
  while i <= last
    if hay[i] == first
      j = 1
      while j < nlen && hay[i + j] == needle[j]
        j += 1
      end
      return i if j == nlen
    end
    i += 1
  end
  nil
end

# Per-worker reusable scratch.
class Scratch
  property data : Bytes
  property low : Bytes
  getter buf : IO::Memory

  def initialize
    @data = Bytes.new(0)
    @low = Bytes.new(0)
    @buf = IO::Memory.new(1 << 16)
  end

  def ensure_data(n : Int32)
    @data = Bytes.new(n) if @data.size < n
  end

  def ensure_low(n : Int32)
    @low = Bytes.new(n) if @low.size < n
  end
end

def search_file(sh : Shared, path : String, sc : Scratch) : Nil
  file = begin
    File.new(path)
  rescue
    return
  end
  begin
    size = file.size.to_i64
    return if size <= 0
    len = size.to_i32
    sc.ensure_data(len)
    data = sc.data

    # Read the 64 KB prefix first.
    peek = len < PREFIX ? len : PREFIX
    off = 0
    while off < peek
      got = file.read(data[off, peek - off])
      break if got <= 0
      off += got
    end
    if off < peek
      peek = off
      len = off
    end

    # NUL-check the prefix; read the rest only if it passes.
    i = 0
    while i < peek
      return if data[i] == 0_u8
      i += 1
    end

    while off < len
      got = file.read(data[off, len - off])
      break if got <= 0
      off += got
    end
    len = off if off < len
  ensure
    file.close
  end

  hay = data
  needle = sh.pat
  if sh.ci
    sc.ensure_low(len)
    ascii_lower_into(sc.low, data, len)
    hay = sc.low
    needle = sh.lpat
  end

  buf = sc.buf
  pos = 0
  while pos <= len
    m = byte_index(hay, len, needle, pos)
    break unless m
    break if m >= len && len > 0
    ls = m
    while ls > 0 && data[ls - 1] != '\n'.ord
      ls -= 1
    end
    le = m
    while le < len && data[le] != '\n'.ord
      le += 1
    end
    sh.mark_match
    buf << path << ':' if sh.multi
    buf.write(data[ls, le - ls])
    buf << '\n'
    pos = le + 1
    pos = m + 1 if needle.size == 0 && pos <= m
  end
end

def worker(sh : Shared) : Nil
  sc = Scratch.new
  loop do
    i = sh.next_index
    break if i >= sh.files.size
    search_file(sh, sh.files[i], sc)
    sh.emit(sc.buf) if sc.buf.bytesize > (1 << 15)
  end
  sh.emit(sc.buf)
end

def collect(path : String, files : Array(String), recursive : Bool) : Nil
  info = File.info?(path, follow_symlinks: false)
  return unless info
  return if info.symlink?
  if info.directory?
    walk(path, files, recursive) if recursive
  elsif info.file?
    files << path
  end
end

def walk(dir : String, files : Array(String), recursive : Bool) : Nil
  entries = begin
    Dir.children(dir)
  rescue
    return
  end
  entries.each do |name|
    collect(File.join(dir, name), files, recursive)
  end
end

def usage
  STDERR.puts "usage: crgrep_std_mt_tuned [-r] [-i] PATTERN PATH..."
  exit 2
end

pat = nil
ci = false
recursive = false
paths = [] of String
no_more = false
ARGV.each do |a|
  if !no_more && a.size >= 2 && a[0] == '-'
    if a == "--"
      no_more = true
      next
    end
    a[1..].each_char do |c|
      case c
      when 'i' then ci = true
      when 'r' then recursive = true
      else          usage
      end
    end
  elsif pat.nil?
    pat = a
  else
    paths << a
  end
end
usage if pat.nil? || paths.empty?

multi = recursive || paths.size > 1

files = [] of String
paths.each do |p|
  info = File.info?(p, follow_symlinks: true)
  next unless info
  if info.directory?
    walk(p, files, recursive) if recursive
  elsif info.file?
    files << p
  end
end

STDOUT.sync = false
STDOUT.flush_on_newline = false

sh = Shared.new(pat, ci, multi, files)

nthreads = System.cpu_count.to_i
nthreads = 16 if nthreads > 16
nthreads = files.size if nthreads > files.size
nthreads = 1 if nthreads < 1

if files.size > 0
  wg = WaitGroup.new(nthreads)
  nthreads.times do
    spawn do
      worker(sh)
      wg.done
    end
  end
  wg.wait
end

STDOUT.flush
exit(sh.matched? ? 0 : 1)
