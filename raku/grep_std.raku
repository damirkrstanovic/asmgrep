# rakugrep_std - idiomatic single-threaded Raku (Rakudo/MoarVM): recursive
# dir walk + whole-file read + literal substring scan + NUL-in-first-64KB
# binary skip. Mirrors python/grep_std.py.
#
# Byte handling: Raku's default Str is Unicode. We decode every Buf as
# 'latin-1' so 1 char == 1 byte exactly, do all .index/.substr work on that
# Str, and write output via $*OUT.write(... .encode('latin-1')) to get raw
# bytes back -- byte-for-byte identical to `grep -F`.

sub fold-ascii(Str $s --> Str) {
    # ASCII-only lowercase: bytes 0x41-0x5A -> +0x20. NOT .lc (Unicode-aware).
    $s.trans('A'..'Z' => 'a'..'z');
}

sub search-file(Str $path, Str $pat, Str $lpat, Bool $ci, Bool $multi, @out --> Bool) {
    my $buf;
    {
        $buf = slurp($path, :bin);
        CATCH { default { return False } }
    }
    my $n = $buf.elems;
    return False if $n == 0;

    # binary skip: NUL in first 64KB
    my $peek = $n < 65536 ?? $n !! 65536;
    for ^$peek -> $i {
        return False if $buf[$i] == 0;
    }

    my $needle = $ci ?? $lpat !! $pat;
    my Int $nlen = $needle.chars;
    my Bool $matched = False;

    # Decoding the whole buffer to a Str is unsafe in general: Raku strings are
    # grapheme-normalized (NFG), so a "\r\n" byte pair (or any multibyte/
    # combining sequence) collapses into ONE grapheme -- char positions then
    # drift from byte positions and .index("\n") never finds CRLF line ends.
    # BUT when no merging happened, $data.chars == byte count, char positions
    # ARE byte positions, and the fast native scan is exact. That holds for the
    # overwhelming majority (ASCII / LF-only source). Fall back to a byte-level
    # line scan only for the rest (CRLF, multibyte), preserving byte-exactness.
    my $data = $buf.decode('latin-1');

    if $data.chars == $n {
        # FAST PATH: 1 grapheme == 1 byte, native .index scan is byte-exact.
        my $hay = $ci ?? fold-ascii($data) !! $data;
        my int $pos = 0;
        loop {
            last if $pos > $n;
            my $m = $hay.index($needle, $pos);
            last if !$m.defined;
            last if $m == $n && $n > 0 && $data.substr($n - 1, 1) eq "\n";
            my $ls = 0;
            if $m > 0 {
                my $prev = $data.rindex("\n", $m - 1);
                $ls = $prev.defined ?? $prev + 1 !! 0;
            }
            my $end = $data.index("\n", $m);
            $end = $end.defined ?? $end !! $n;
            $matched = True;
            if $multi { @out.push($path); @out.push(":"); }
            @out.push($data.substr($ls, $end - $ls));
            @out.push("\n");
            $pos = $end + 1;
        }
    } else {
        # SAFE PATH: scan line-by-line at the byte level. Splitting on \n (0x0A)
        # bytes first means each segment has no "\r\n" adjacency, so decoding it
        # to latin-1 stays 1 char == 1 byte. The trailing \r (CRLF) stays in the
        # line, exactly as grep keeps it.
        my int $ls = 0;
        while $ls < $n {
            my int $le = $ls;
            while $le < $n && $buf[$le] != 0x0A { $le = $le + 1; }
            my $line = $buf.subbuf($ls, $le - $ls).decode('latin-1');
            my $hay  = $ci ?? fold-ascii($line) !! $line;
            if $nlen == 0 || $hay.contains($needle) {
                $matched = True;
                if $multi { @out.push($path); @out.push(":"); }
                @out.push($line);
                @out.push("\n");
            }
            $ls = $le + 1;
        }
    }
    return $matched;
}

sub walk(Str $path, Str $pat, Str $lpat, Bool $ci, Bool $multi, @out --> Bool) {
    my Bool $matched = False;
    my @stack = $path;
    while @stack {
        my $d = @stack.pop;
        my @entries;
        {
            @entries = dir($d);
            CATCH { default { next } }
        }
        for @entries -> $e {
            my $p = $e.Str;
            next if $p.IO.l;                       # skip symlinks (don't follow)
            if $p.IO.d {
                @stack.push($p);
            }
            elsif $p.IO.f {
                $matched = True if search-file($p, $pat, $lpat, $ci, $multi, @out);
            }
        }
    }
    return $matched;
}

sub MAIN-LOGIC(--> Int) {
    my Bool $ci = False;
    my Bool $r  = False;
    my $pat;
    my @paths;
    my Bool $no-more = False;

    for @*ARGS -> $a {
        if !$no-more && $a.starts-with('-') && $a ne '-' {
            if $a eq '--' {
                $no-more = True;
                next;
            }
            for $a.substr(1).comb -> $q {
                if $q eq 'i' { $ci = True }
                elsif $q eq 'r' { $r = True }
                else {
                    $*ERR.print("usage: rakugrep_std [-r] [-i] PATTERN PATH...\n");
                    return 2;
                }
            }
        }
        elsif !$pat.defined {
            $pat = $a;
        }
        else {
            @paths.push($a);
        }
    }

    if !$pat.defined || !@paths {
        $*ERR.print("usage: rakugrep_std [-r] [-i] PATTERN PATH...\n");
        return 2;
    }

    # @*ARGS strings are already decoded; re-encode the pattern as latin-1 bytes
    # then back so it lines up byte-wise with file data. Practically the
    # patterns here are ASCII; treat the arg directly as the latin-1 char view.
    my Str $patb = $pat;
    my Str $lpat = fold-ascii($patb);
    my Bool $multi = $r || @paths.elems > 1;

    my @out;
    my Bool $matched = False;
    for @paths -> $p {
        # top-level: stat, FOLLOWING symlinks
        next unless $p.IO.e;
        if $p.IO.d {                                # follows symlinks via .d
            $matched = True if $r && walk($p, $patb, $lpat, $ci, $multi, @out);
        }
        elsif $p.IO.f {
            $matched = True if search-file($p, $patb, $lpat, $ci, $multi, @out);
        }
    }

    if @out {
        $*OUT.write(@out.join('').encode('latin-1'));
    }
    $*OUT.flush;
    return $matched ?? 0 !! 1;
}

exit MAIN-LOGIC();
