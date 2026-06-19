#!/usr/bin/env luajit
-- ljgrep_std_mt - LuaJIT has NO threads, so "parallel" here means real OS
-- parallelism via fork(): the parent collects the file list, forks N children
-- (N = online CPUs, capped), each child searches a STRIDED slice of the list
-- (index % N == id) and writes its matches to the shared stdout, then exits
-- with status 0 if it matched / 1 if not. The parent waits and exits 0 iff any
-- child matched. Cross-file (and cross-child) output order is unspecified --
-- the verify harness sorts -- but each write is chunked on LINE boundaries so a
-- line is never torn between two concurrent children.
package.path = (arg[0]:match("^(.*/)") or "./") .. "?.lua;" .. package.path
local core = require("grep_core")
local ffi  = core.ffi
local C    = ffi.C
local band = require("bit").band

ffi.cdef[[
typedef int pid_t;
pid_t fork(void);
pid_t waitpid(pid_t pid, int *status, int options);
long  write(int fd, const char *buf, unsigned long count);
long  sysconf(int name);
void  _exit(int status);
int   open(const char *path, int flags, int mode);
int   close(int fd);
int   unlink(const char *path);
int   flock(int fd, int operation);
]]
local SC_NPROCESSORS_ONLN = 84   -- glibc
local O_RDWR, O_CREAT = 02, 0100
local LOCK_EX, LOCK_UN = 2, 8

local pat, paths, ci, r = core.parse_args(arg)
if not pat then
    io.stderr:write("usage: ljgrep_std_mt [-r] [-i] PATTERN PATH...\n")
    os.exit(2)
end
local multi  = r or #paths > 1
local needle = ci and core.ascii_lower(pat) or pat

-- ---- collect the file list (parent, before forking) ----
local files, nf = {}, 0
local function add(p) nf = nf + 1; files[nf] = p end
for _, p in ipairs(paths) do
    local kind = core.classify(p)
    if kind == "dir" then
        if r then core.walk(p, add) end
    elseif kind == "file" then
        add(p)
    end
end

local function nworkers()
    local n = tonumber(C.sysconf(SC_NPROCESSORS_ONLN)) or 1
    if n < 1 then n = 1 end
    if n > 16 then n = 16 end
    if n > nf then n = nf end
    if n < 1 then n = 1 end
    return n
end

-- Cross-process output lock: a fork()ed worker pool shares one stdout, and a
-- match line can exceed PIPE_BUF (4096) -- so atomic-pipe chunking can't prevent
-- tears for long lines. Instead each worker writes its WHOLE buffer while holding
-- an flock() on a shared lockfile (the cross-process analogue of the C mutex).
-- flock works on a regular file regardless of whether stdout is a pipe or file.
local g_lockfd = -1
local function write_out(buf)
    if g_lockfd >= 0 then C.flock(g_lockfd, LOCK_EX) end
    local len = #buf
    local off = 0
    while off < len do
        local p = ffi.cast("const char*", buf) + off
        local n = tonumber(C.write(1, p, len - off))
        if n <= 0 then break end
        off = off + n
    end
    if g_lockfd >= 0 then C.flock(g_lockfd, LOCK_UN) end
end

local function run_slice(id, n)
    local out, nout = {}, 0
    local matched = false
    local function emit(path, line, m)
        if m then
            nout = nout + 1; out[nout] = path
            nout = nout + 1; out[nout] = ":"
        end
        nout = nout + 1; out[nout] = line
        nout = nout + 1; out[nout] = "\n"
    end
    local i = id + 1
    while i <= nf do
        local path = files[i]
        local f = io.open(path, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            if data and #data > 0 then
                local peek = #data < 65536 and data or data:sub(1, 65536)
                if not core.is_binary(peek) then
                    if core.scan(data, needle, ci, path, multi, emit) then
                        matched = true
                    end
                end
            end
        end
        i = i + n
    end
    if nout > 0 then write_out(table.concat(out)) end
    return matched
end

-- ---- shared output lock ----
-- The lockfile PATH is created in the parent, but each child must open() it
-- INDEPENDENTLY: flock arbitrates between distinct open file descriptions, and
-- fork-inherited duplicates of one description share the lock reentrantly (no
-- arbitration). So we pass the path and let each child open its own fd.
local n = nworkers()
local lockpath = nil
if n > 1 then
    lockpath = os.tmpname()
    local fd = C.open(lockpath, O_RDWR + O_CREAT, 0x180)  -- ensure it exists
    if fd >= 0 then C.close(fd) end
end

-- ---- fork the workers ----
local kids = {}
for id = 0, n - 1 do
    local pid = tonumber(C.fork())
    if pid == 0 then
        -- child: open our OWN handle on the lockfile for real flock arbitration
        if lockpath then g_lockfd = C.open(lockpath, O_RDWR, 0x180) end
        local ok = run_slice(id, n)
        if g_lockfd >= 0 then C.close(g_lockfd) end
        C._exit(ok and 0 or 1)
    elseif pid > 0 then
        kids[#kids + 1] = pid
    else
        -- fork failed: do this slice inline in the parent
        run_slice(id, n)
    end
end

-- ---- parent waits; matched iff any child exited 0 ----
local any_match = false
local status = ffi.new("int[1]")
for _ = 1, #kids do
    C.waitpid(-1, status, 0)
    local st = status[0]
    -- WIFEXITED && WEXITSTATUS==0  =>  matched
    local exited = band(st, 0x7f) == 0
    local code = math.floor(st / 256) % 256
    if exited and code == 0 then any_match = true end
end
if lockpath then C.unlink(lockpath) end
os.exit(any_match and 0 or 1)
