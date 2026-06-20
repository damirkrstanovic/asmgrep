# jlgrep_std - idiomatic single-threaded Julia: walkdir recursive walk (skip
# symlinks) + whole-file read(path) -> Vector{UInt8} + byte-oriented literal
# search via findnext + NUL-in-first-64KB binary skip. Mirrors c/grep_std.c.
# Stays byte-oriented (Vector{UInt8}) for grep -F parity; ASCII-only -i fold.

const PREFIX = 65536
const NL = 0x0a

# ASCII lowercase fold for a single byte (0x41..0x5A -> +0x20); NOT Unicode.
@inline lc(b::UInt8) = (0x41 <= b <= 0x5A) ? (b + 0x20) : b

# fold src[1:n] into dst (dst must be length >= n)
function fold!(dst::Vector{UInt8}, src::Vector{UInt8}, n::Int)
    @inbounds for k in 1:n
        dst[k] = lc(src[k])
    end
    return dst
end

# find `needle` in hay[1:n] starting at 1-based `from`; returns start or 0.
# Empty needle matches at `from` (up to n+1) like grep -F "".
@inline function _find(hay::Vector{UInt8}, needle::Vector{UInt8}, n::Int, from::Int)
    pl = length(needle)
    if pl == 0
        return from <= n + 1 ? from : 0
    end
    from > n - pl + 1 && return 0
    r = findnext(needle, hay, from)
    r === nothing && return 0
    f = first(r)
    f > n - pl + 1 ? 0 : f
end

# scan data[1:n] for literal needle; append "path:line\n" (or "line\n") per match
function scan!(out::Vector{UInt8}, data::Vector{UInt8}, hay::Vector{UInt8},
               n::Int, needle::Vector{UInt8}, path::Vector{UInt8}, multi::Bool)
    matched = false
    pos = 1
    @inbounds while pos <= n + 1
        m = _find(hay, needle, n, pos)
        m == 0 && break
        # phantom empty line after a trailing newline: grep emits nothing there
        if m == n + 1 && n > 0 && data[n] == NL
            break
        end
        ls = m
        while ls > 1 && data[ls-1] != NL
            ls -= 1
        end
        le = m
        while le <= n && data[le] != NL
            le += 1
        end
        matched = true
        if multi
            append!(out, path)
            push!(out, 0x3a)            # ':'
        end
        append!(out, @view data[ls:le-1])
        push!(out, NL)
        pos = le + 1
    end
    return matched
end

read_bytes(path::String) = try read(path) catch; nothing end

function process_file(path::String, needle::Vector{UInt8}, lneedle::Vector{UInt8},
                      ci::Bool, multi::Bool, out::Vector{UInt8})
    data = read_bytes(path)
    data === nothing && return false
    n = length(data)
    n == 0 && return false
    peek = n < PREFIX ? n : PREFIX
    findfirst(==(0x00), @view data[1:peek]) === nothing || return false  # binary skip
    pathb = Vector{UInt8}(codeunits(path))
    if ci
        hay = Vector{UInt8}(undef, n)
        fold!(hay, data, n)
        return scan!(out, data, hay, n, lneedle, pathb, multi)
    else
        return scan!(out, data, data, n, needle, pathb, multi)
    end
end

function walk(root::String, needle::Vector{UInt8}, lneedle::Vector{UInt8},
              ci::Bool, multi::Bool, out::Vector{UInt8})
    matched = false
    for (dir, _, files) in walkdir(root; follow_symlinks=false, onerror=x->nothing)
        for f in files
            p = joinpath(dir, f)
            islink(p) && continue          # don't follow symlinks (grep -r)
            isfile(p) || continue
            process_file(p, needle, lneedle, ci, multi, out) && (matched = true)
        end
    end
    return matched
end

function run(args::Vector{String})
    ci = false; r = false
    pat = nothing
    paths = String[]
    no_more = false
    for a in args
        if !no_more && startswith(a, "-") && a != "-"
            if a == "--"
                no_more = true
                continue
            end
            for q in a[2:end]
                if q == 'i'
                    ci = true
                elseif q == 'r'
                    r = true
                else
                    write(stderr, "usage: jlgrep_std [-r] [-i] PATTERN PATH...\n")
                    return 2
                end
            end
        elseif pat === nothing
            pat = a
        else
            push!(paths, a)
        end
    end
    if pat === nothing || isempty(paths)
        write(stderr, "usage: jlgrep_std [-r] [-i] PATTERN PATH...\n")
        return 2
    end

    needle = Vector{UInt8}(codeunits(pat))
    lneedle = copy(needle)
    fold!(lneedle, needle, length(needle))
    multi = r || length(paths) > 1

    out = UInt8[]
    matched = false
    for p in paths
        local st
        try
            st = stat(p)
        catch
            continue
        end
        if isdir(st)
            r && walk(p, needle, lneedle, ci, multi, out) && (matched = true)
        elseif isfile(st)
            process_file(p, needle, lneedle, ci, multi, out) && (matched = true)
        end
    end

    isempty(out) || write(stdout, out)
    flush(stdout)
    return matched ? 0 : 1
end

exit(run(ARGS))
