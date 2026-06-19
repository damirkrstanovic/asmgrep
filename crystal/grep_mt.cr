# crgrep_std_mt - idiomatic Crystal, multithreaded (NAIVE memory strategy).
# Built with -Dpreview_mt so fibers run on real OS threads (CRYSTAL_WORKERS).
# A directory walk collects the file list, then N worker fibers pull files off a
# shared atomic index and search them in parallel. Each file is freshly read with
# File.read (fresh allocation per file) -- this is the un-tuned variant, mirroring
# c/grep_std_mt.c WITHOUT the buffer-reuse / prefix-check pillar.
# Output: each worker batches into its own buffer, flushed under a mutex.

require "wait_group"

PREFIX = 65536

def ascii_lower(s : String) : String
  bytes = s.to_slice.dup
  bytes.map! { |b| (b >= 'A'.ord && b <= 'Z'.ord) ? (b &+ 32_u8) : b }
  String.new(bytes)
end

class Shared
  getter pat : String
  getter lpat : String
  getter ci : Bool
  getter multi : Bool
  getter files : Array(String)

  def initialize(@pat : String, @ci : Bool, @multi : Bool, @files : Array(String))
    @lpat = ascii_lower(@pat)
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

def search_file(sh : Shared, path : String, buf : IO::Memory) : Nil
  data = begin
    File.read(path)
  rescue
    return
  end
  return if data.bytesize == 0

  slice = data.to_slice
  peek = slice.size < PREFIX ? slice.size : PREFIX
  peek.times do |i|
    return if slice[i] == 0_u8
  end

  hay = sh.ci ? ascii_lower(data) : data
  needle = sh.ci ? sh.lpat : sh.pat

  pos = 0
  while pos <= slice.size
    m = hay.byte_index(needle, pos)
    break unless m
    break if m >= slice.size && slice.size > 0
    ls = m
    while ls > 0 && slice[ls - 1] != '\n'.ord
      ls -= 1
    end
    le = m
    while le < slice.size && slice[le] != '\n'.ord
      le += 1
    end
    sh.mark_match
    buf << path << ':' if sh.multi
    buf.write(slice[ls, le - ls])
    buf << '\n'
    pos = le + 1
    pos = m + 1 if needle.bytesize == 0 && pos <= m
  end
end

def worker(sh : Shared) : Nil
  buf = IO::Memory.new(1 << 16)
  loop do
    i = sh.next_index
    break if i >= sh.files.size
    search_file(sh, sh.files[i], buf)
    sh.emit(buf) if buf.bytesize > (1 << 15)
  end
  sh.emit(buf)
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
  STDERR.puts "usage: crgrep_std_mt [-r] [-i] PATTERN PATH..."
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
