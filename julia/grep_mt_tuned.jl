# jlgrep_std_mt_tuned - Threads.@threads + the memory pillar (mirrors
# c/grep_std_mt.c): a PER-THREAD reused read buffer (a Vector{Vector{UInt8}}
# indexed by threadid under :static scheduling, so each task owns a stable slot)
# + read a 64KB PREFIX first, binary-check it, and read the rest ONLY if the
# file isn't binary -- so a 291MB .git pack is never fully faulted in then
# skipped. Per-thread output buffers, merged in order at the end.

include(joinpath(@__DIR__, "grep_core.jl"))

# Read into a reused buffer, prefix-first. Returns the number of valid bytes
# (0 on error/empty), or -1 to signal "binary, skip". `buf[]` may be grown
# (resize!) and the new length is reflected back through the Ref.
function read_into!(buf::Vector{UInt8}, path::String)
    io = nothing
    try
        io = open(path, "r")
    catch
        return 0, buf
    end
    try
        sz = try filesize(path) catch; -1 end
        sz == 0 && return 0, buf
        peek = (sz < 0 || sz > PREFIX) ? PREFIX : Int(sz)
        length(buf) < peek && resize!(buf, peek)
        got = readbytes!(io, buf, peek)
        got == 0 && return 0, buf
        # binary: NUL in the prefix -> skip, rest unread
        findfirst(==(0x00), @view buf[1:got]) === nothing || return -1, buf
        # read the rest only if not binary
        if sz < 0 || sz > got
            total = Int(got)
            if sz > 0
                length(buf) < sz && resize!(buf, Int(sz))
                while total < sz
                    n = readbytes!(io, @view(buf[total+1:end]), Int(sz) - total)
                    n == 0 && break
                    total += n
                end
            else
                # unknown size: double-and-read until EOF
                while true
                    total >= length(buf) && resize!(buf, length(buf) * 2)
                    n = readbytes!(io, @view(buf[total+1:end]), length(buf) - total)
                    n == 0 && break
                    total += n
                end
            end
            got = total
        end
        return Int(got), buf
    catch
        return 0, buf
    finally
        io === nothing || close(io)
    end
end

function search_one!(out::Vector{UInt8}, rbuf::Vector{UInt8}, lbuf::Vector{UInt8},
                     path::String, needle::Vector{UInt8}, lneedle::Vector{UInt8},
                     ci::Bool, multi::Bool)
    got, rbuf = read_into!(rbuf, path)
    got <= 0 && return false, rbuf, lbuf      # 0 = empty/error, -1 = binary
    n = got
    pathb = Vector{UInt8}(codeunits(path))
    if ci
        length(lbuf) < n && resize!(lbuf, n)
        fold!(lbuf, rbuf, n)
        m = scan!(out, rbuf, lbuf, n, lneedle, pathb, multi)
    else
        m = scan!(out, rbuf, rbuf, n, needle, pathb, multi)
    end
    return m, rbuf, lbuf
end

function run(args::Vector{String})
    p = parse_args(args, "jlgrep_std_mt_tuned")
    p isa Int && return p
    ci, r, pat, paths = p

    needle = Vector{UInt8}(codeunits(pat))
    lneedle = copy(needle); fold!(lneedle, needle, length(needle))
    multi = r || length(paths) > 1

    files = collect_files(paths, r)

    # size per-thread state by maxthreadid(), NOT nthreads(): under `-t auto`
    # the interactive threadpool means threadid() can exceed nthreads().
    nt = Threads.maxthreadid()
    bufs = [UInt8[] for _ in 1:nt]                # per-thread output
    rbufs = [Vector{UInt8}(undef, PREFIX) for _ in 1:nt]  # per-thread reused read buffer
    lbufs = [UInt8[] for _ in 1:nt]               # per-thread reused fold buffer
    hits = falses(nt)

    Threads.@threads :static for i in eachindex(files)
        t = Threads.threadid()
        m, rbufs[t], lbufs[t] =
            search_one!(bufs[t], rbufs[t], lbufs[t], files[i],
                        needle, lneedle, ci, multi)
        m && (hits[t] = true)
    end

    for b in bufs
        isempty(b) || write(stdout, b)
    end
    flush(stdout)
    return any(hits) ? 0 : 1
end

exit(run(ARGS))
