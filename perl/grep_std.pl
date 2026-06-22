#!/usr/bin/env perl
# perlgrep_std - idiomatic single-threaded Perl: recursive readdir walk +
# whole-file slurp + index() literal scan + NUL-in-first-64KB binary skip.
# Mirrors python/grep_std.py. index()/rindex are C-backed under the
# interpreter; ASCII case-fold is a tr/// (also C). No regex (this project's
# literal, regex-free semantics == grep -F).
use strict;
use warnings;

# search one file, appending matching lines to $$out; returns 1 if any matched.
sub search_file {
    my ($path, $pat, $lpat, $ci, $multi, $out) = @_;
    open(my $fh, '<:raw', $path) or return 0;
    my $data = do { local $/; <$fh> };
    close($fh);
    return 0 unless defined $data;
    my $n = length $data;
    return 0 if $n == 0;
    my $peek = $n > 65536 ? substr($data, 0, 65536) : $data;
    return 0 if index($peek, "\0") >= 0;          # binary skip

    my ($hay, $needle);
    if ($ci) { ($hay = $data) =~ tr/A-Z/a-z/; $needle = $lpat; }
    else     { $hay = $data;                  $needle = $pat;  }

    my $matched = 0;
    my $pos = 0;
    while ($pos <= $n) {
        my $m = index($hay, $needle, $pos);
        last if $m < 0;
        # phantom empty line after a trailing newline: grep emits nothing there
        last if $m == $n && $n > 0 && substr($data, $n - 1, 1) eq "\n";
        my $ls = $m == 0 ? 0 : rindex($data, "\n", $m - 1) + 1;  # prev '\n'+1 (or 0)
        my $le = index($data, "\n", $m);
        $le = $n if $le < 0;
        $matched = 1;
        $$out .= "$path:" if $multi;
        $$out .= substr($data, $ls, $le - $ls) . "\n";
        $pos = $le + 1;
    }
    return $matched;
}

# recursive walk: skip symlinks (grep -r), recurse dirs, search regular files.
sub walk {
    my ($dir, $pat, $lpat, $ci, $multi, $out) = @_;
    my $matched = 0;
    opendir(my $dh, $dir) or return 0;
    my @ents = readdir $dh;
    closedir $dh;
    for my $e (@ents) {
        next if $e eq '.' || $e eq '..';
        my $p = "$dir/$e";
        next if -l $p;                            # don't follow symlinks
        if    (-d _) { $matched = 1 if walk($p, $pat, $lpat, $ci, $multi, $out); }
        elsif (-f _) { $matched = 1 if search_file($p, $pat, $lpat, $ci, $multi, $out); }
    }
    return $matched;
}

sub main {
    my ($ci, $r, $no_more) = (0, 0, 0);
    my $pat;
    my @paths;
    for my $a (@ARGV) {
        if (!$no_more && $a =~ /^-/ && $a ne '-') {
            if ($a eq '--') { $no_more = 1; next; }
            for my $q (split //, substr($a, 1)) {
                if    ($q eq 'i') { $ci = 1; }
                elsif ($q eq 'r') { $r  = 1; }
                else { print STDERR "usage: perlgrep_std [-r] [-i] PATTERN PATH...\n"; return 2; }
            }
        } elsif (!defined $pat) { $pat = $a; }
        else                    { push @paths, $a; }
    }
    if (!defined $pat || !@paths) {
        print STDERR "usage: perlgrep_std [-r] [-i] PATTERN PATH...\n";
        return 2;
    }

    my $lpat = $pat;
    $lpat =~ tr/A-Z/a-z/;
    my $multi = $r || @paths > 1;

    my $out = '';
    my $matched = 0;
    for my $p (@paths) {
        my @st = stat $p;                         # follow symlinks at top level
        next unless @st;
        if    (-d _) { $matched = 1 if $r && walk($p, $pat, $lpat, $ci, $multi, \$out); }
        elsif (-f _) { $matched = 1 if search_file($p, $pat, $lpat, $ci, $multi, \$out); }
    }

    binmode STDOUT;
    print STDOUT $out if length $out;
    return $matched ? 0 : 1;
}

exit main();
