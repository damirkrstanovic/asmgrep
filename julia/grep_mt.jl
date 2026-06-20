# jlgrep_std_mt - Threads.@threads over the collected file list (REQUIRES the
# runtime have threads: the launcher passes `-t auto`). Naive per-file
# allocation: read(path) -> a fresh Vector{UInt8} every file. Per-thread output
# buffers, merged at the end; a matched flag is OR'd via a per-thread array.

include(joinpath(@__DIR__, "grep_core.jl"))

read_bytes(path::String) = try read(path) catch; nothing end

function search_one!(out::Vector{UInt8}, path::String, needle::Vector{UInt8},
                     lneedle::Vector{UInt8}, ci::Bool, multi::Bool)
    data = read_bytes(path)
    data === nothing && return false
    n = length(data)
    n == 0 && return false
    peek = n < PREFIX ? n : PREFIX
    findfirst(==(0x00), @view data[1:peek]) === nothing || return false
    pathb = Vector{UInt8}(codeunits(path))
    if ci
        hay = Vector{UInt8}(undef, n)
        fold!(hay, data, n)
        return scan!(out, data, hay, n, lneedle, pathb, multi)
    else
        return scan!(out, data, data, n, needle, pathb, multi)
    end
end

function run(args::Vector{String})
    p = parse_args(args, "jlgrep_std_mt")
    p isa Int && return p
    ci, r, pat, paths = p

    needle = Vector{UInt8}(codeunits(pat))
    lneedle = copy(needle); fold!(lneedle, needle, length(needle))
    multi = r || length(paths) > 1

    files = collect_files(paths, r)

    # size per-thread state by maxthreadid(), NOT nthreads(): under `-t auto`
    # the interactive threadpool means threadid() can exceed nthreads().
    nt = Threads.maxthreadid()
    # per-thread output buffers + matched flags (no locking on the hot path;
    # buffers are merged in order at the end).
    bufs = [UInt8[] for _ in 1:nt]
    hits = falses(nt)

    Threads.@threads :static for i in eachindex(files)
        t = Threads.threadid()
        if search_one!(bufs[t], files[i], needle, lneedle, ci, multi)
            hits[t] = true
        end
    end

    for b in bufs
        isempty(b) || write(stdout, b)
    end
    flush(stdout)
    return any(hits) ? 0 : 1
end

exit(run(ARGS))
