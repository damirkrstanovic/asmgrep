# crgrep_std - idiomatic single-threaded Crystal grep -F clone.
# Ruby-like syntax, but LLVM-compiled to a native binary with a GC.
# Dir walk (skipping symlinks), whole-file read into a String, stdlib
# String#byte_index literal (fixed-string, NO regex) search. NUL-in-first-64KB
# binary skip. ASCII-lowercase for -i. Batched output to STDOUT.
# Mirrors c/grep_std.c semantics.

PREFIX = 65536

# ASCII-only, length-preserving lowercase (matches grep -iF).
def ascii_lower(s : String) : String
  bytes = s.to_slice.dup
  bytes.map! { |b| (b >= 'A'.ord && b <= 'Z'.ord) ? (b &+ 32_u8) : b }
  String.new(bytes)
end

class Grep
  @pat : String
  @lpat : String

  def initialize(@pat : String, @ci : Bool, @recursive : Bool, @multi : Bool, @sink : IO)
    @lpat = ascii_lower(@pat)
    @matched = false
  end

  getter matched

  def search_file(path : String) : Nil
    data = begin
      File.read(path)
    rescue
      return
    end
    return if data.bytesize == 0

    peek = data.bytesize < PREFIX ? data.bytesize : PREFIX
    # binary skip: NUL byte in first 64 KB
    slice = data.to_slice
    peek.times do |i|
      return if slice[i] == 0_u8
    end

    hay = @ci ? ascii_lower(data) : data
    needle = @ci ? @lpat : @pat
    nlen = needle.bytesize

    pos = 0
    while pos <= data.bytesize
      m = hay.byte_index(needle, pos)
      break unless m
      # empty-pattern match at EOF (past the final newline) is not a line
      break if m >= slice.size && slice.size > 0
      # line bounds in the ORIGINAL bytes
      ls = m
      while ls > 0 && slice[ls - 1] != '\n'.ord
        ls -= 1
      end
      le = m
      while le < slice.size && slice[le] != '\n'.ord
        le += 1
      end
      @matched = true
      @sink << path << ':' if @multi
      @sink.write(slice[ls, le - ls])
      @sink << '\n'
      pos = le + 1
      # empty pattern: byte_index returns pos each time; force forward progress
      pos = m + 1 if nlen == 0 && pos <= m
    end
  end

  def walk(dir : String) : Nil
    entries = begin
      Dir.children(dir)
    rescue
      return
    end
    entries.each do |name|
      collect(File.join(dir, name))
    end
  end

  # recursive descent: skip symlinks, don't follow them
  def collect(path : String) : Nil
    info = File.info?(path, follow_symlinks: false)
    return unless info
    return if info.symlink?
    if info.directory?
      walk(path) if @recursive
    elsif info.file?
      search_file(path)
    end
  end
end

def usage
  STDERR.puts "usage: crgrep_std [-r] [-i] PATTERN PATH..."
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

sink = STDOUT
sink.sync = false
sink.flush_on_newline = false

g = Grep.new(pat, ci, recursive, multi, sink)

paths.each do |p|
  info = File.info?(p, follow_symlinks: true)
  next unless info
  if info.directory?
    g.walk(p) if recursive
  elsif info.file?
    g.search_file(p)
  end
end

sink.flush
exit(g.matched ? 0 : 1)
