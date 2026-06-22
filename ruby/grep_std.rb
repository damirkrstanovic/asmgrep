# frozen_string_literal: true
# rubygrep_std - idiomatic single-threaded Ruby: recursive walk + whole-file
# binread + String#index literal scan + NUL-in-first-64KB binary skip.
# Mirrors python/grep_std.py. Strings are forced to ASCII-8BIT so index/rindex
# work in byte positions (C-backed); ASCII case-fold is a tr (also C). No regex.

NL = "\n".b
NUL = "\x00".b

def search_file(path, pat, lpat, ci, multi, out)
  data = begin
    File.binread(path)
  rescue SystemCallError
    return false
  end
  return false if data.empty?
  n = data.bytesize
  peek = n > 65536 ? data.byteslice(0, 65536) : data
  return false if peek.include?(NUL)            # binary skip

  if ci
    hay = data.tr('A-Z', 'a-z')
    needle = lpat
  else
    hay = data
    needle = pat
  end

  matched = false
  pos = 0
  while pos <= n
    m = hay.index(needle, pos)
    break if m.nil?
    # phantom empty line after a trailing newline: grep emits nothing there
    break if m == n && n.positive? && data.getbyte(n - 1) == 0x0A
    ls = m.zero? ? 0 : (data.rindex(NL, m - 1) || -1) + 1
    le = data.index(NL, m) || n
    matched = true
    out << path << ':' if multi
    out << data.byteslice(ls, le - ls) << "\n"
    pos = le + 1
  end
  matched
end

def walk(dir, pat, lpat, ci, multi, out)
  matched = false
  entries = begin
    Dir.children(dir)
  rescue SystemCallError
    return false
  end
  entries.each do |e|
    p = File.join(dir, e)
    begin
      st = File.lstat(p)
    rescue SystemCallError
      next
    end
    next if st.symlink?                          # don't follow symlinks (grep -r)
    if st.directory?
      matched = true if walk(p, pat, lpat, ci, multi, out)
    elsif st.file?
      matched = true if search_file(p, pat, lpat, ci, multi, out)
    end
  end
  matched
end

def main(argv)
  ci = r = false
  no_more = false
  pat = nil
  paths = []
  argv.each do |a|
    if !no_more && a.start_with?('-') && a != '-'
      if a == '--'
        no_more = true
        next
      end
      a[1..].each_char do |q|
        case q
        when 'i' then ci = true
        when 'r' then r = true
        else
          warn 'usage: rubygrep_std [-r] [-i] PATTERN PATH...'
          return 2
        end
      end
    elsif pat.nil?
      pat = a
    else
      paths << a
    end
  end
  if pat.nil? || paths.empty?
    warn 'usage: rubygrep_std [-r] [-i] PATTERN PATH...'
    return 2
  end

  patb = pat.b
  lpat = patb.tr('A-Z', 'a-z')
  multi = r || paths.size > 1

  out = +''.b
  matched = false
  paths.each do |p|
    st = begin
      File.stat(p)                               # follow symlinks at top level
    rescue SystemCallError
      next
    end
    if st.directory?
      matched = true if r && walk(p, patb, lpat, ci, multi, out)
    elsif st.file?
      matched = true if search_file(p, patb, lpat, ci, multi, out)
    end
  end

  STDOUT.binmode
  STDOUT.write(out) unless out.empty?
  matched ? 0 : 1
end

exit main(ARGV)
