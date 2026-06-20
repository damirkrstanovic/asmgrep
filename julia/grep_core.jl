# Shared byte-oriented grep core for the Julia variants. Pure functions over
# Vector{UInt8} so they work identically single- and multi-threaded.

const PREFIX = 65536
const NL = 0x0a

@inline lc(b::UInt8) = (0x41 <= b <= 0x5A) ? (b + 0x20) : b

function fold!(dst::Vector{UInt8}, src::Vector{UInt8}, n::Int)
    @inbounds for k in 1:n
        dst[k] = lc(src[k])
    end
    return dst
end

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

# scan data[1:n] for literal needle; append "path:line\n" (or "line\n") to out.
function scan!(out::Vector{UInt8}, data::Vector{UInt8}, hay::Vector{UInt8},
               n::Int, needle::Vector{UInt8}, path::Vector{UInt8}, multi::Bool)
    matched = false
    pos = 1
    @inbounds while pos <= n + 1
        m = _find(hay, needle, n, pos)
        m == 0 && break
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
            push!(out, 0x3a)
        end
        append!(out, @view data[ls:le-1])
        push!(out, NL)
        pos = le + 1
    end
    return matched
end

# collect regular-file paths from the given roots (recursing iff r).
function collect_files(paths::Vector{String}, r::Bool)
    files = String[]
    for p in paths
        local st
        try
            st = stat(p)
        catch
            continue
        end
        if isdir(st)
            r || continue
            for (dir, _, fs) in walkdir(p; follow_symlinks=false, onerror=x->nothing)
                for f in fs
                    q = joinpath(dir, f)
                    islink(q) && continue
                    isfile(q) && push!(files, q)
                end
            end
        elseif isfile(st)
            push!(files, p)
        end
    end
    return files
end

# parse args -> (ci, r, pat, paths) or an Int exit code on usage error.
function parse_args(args::Vector{String}, prog::String)
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
                    write(stderr, "usage: $prog [-r] [-i] PATTERN PATH...\n")
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
        write(stderr, "usage: $prog [-r] [-i] PATTERN PATH...\n")
        return 2
    end
    return (ci, r, pat::String, paths)
end
