#!/usr/bin/env luajit
-- ljgrep_std_mt_tuned - the fork() worker model of grep_mt.lua plus the I/O
-- pillar from c/grep_std_mt.c: read only the 64KB PREFIX first, check it for a
-- NUL (binary), and read the REST *only* if the file isn't binary. That keeps a
-- 291MB .git pack from being faulted in just to be skipped.
--
-- Lua strings are immutable, so the C trick of a single *reused* per-worker
-- buffer doesn't map; instead each worker reads prefix-then-rest with io.read,
-- which is the honest LuaJIT equivalent of "don't touch the bytes you'll skip".
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
local SC_NPROCESSORS_ONLN = 84
local O_RDWR, O_CREAT = 02, 0100
local LOCK_EX, LOCK_UN = 2, 8

local pat, paths, ci, r = core.parse_args(arg)
if not pat then
    io.stderr:write("usage: ljgrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n")
    os.exit(2)
end
local multi  = r or #paths > 1
local needle = ci and core.ascii_lower(pat) or pat
local PEEK   = 65536

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

-- each worker writes its WHOLE buffer while holding an flock() on a shared
-- lockfile -- the cross-process analogue of the C mutexed flush (long lines can
-- exceed PIPE_BUF, so atomic-pipe chunking isn't enough). See grep_mt.lua.
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
            -- prefix-first: read 64KB, binary-check, read the rest only if clean
            local prefix = f:read(PEEK)
            if prefix and #prefix > 0 then
                if not core.is_binary(prefix) then
                    local data = prefix
                    if #prefix == PEEK then
                        local rest = f:read("*a")
                        if rest and #rest > 0 then data = prefix .. rest end
                    end
                    if core.scan(data, needle, ci, path, multi, emit) then
                        matched = true
                    end
                end
            end
            f:close()
        end
        i = i + n
    end
    if nout > 0 then write_out(table.concat(out)) end
    return matched
end

-- lockfile path created in the parent; each child opens its OWN fd so flock
-- actually arbitrates (fork-inherited duplicate descriptions lock reentrantly).
local n = nworkers()
local lockpath = nil
if n > 1 then
    lockpath = os.tmpname()
    local fd = C.open(lockpath, O_RDWR + O_CREAT, 0x180)
    if fd >= 0 then C.close(fd) end
end

local kids = {}
for id = 0, n - 1 do
    local pid = tonumber(C.fork())
    if pid == 0 then
        if lockpath then g_lockfd = C.open(lockpath, O_RDWR, 0x180) end
        local ok = run_slice(id, n)
        if g_lockfd >= 0 then C.close(g_lockfd) end
        C._exit(ok and 0 or 1)
    elseif pid > 0 then
        kids[#kids + 1] = pid
    else
        run_slice(id, n)
    end
end

local any_match = false
local status = ffi.new("int[1]")
for _ = 1, #kids do
    C.waitpid(-1, status, 0)
    local st = status[0]
    local exited = band(st, 0x7f) == 0
    local code = math.floor(st / 256) % 256
    if exited and code == 0 then any_match = true end
end
if lockpath then C.unlink(lockpath) end
os.exit(any_match and 0 or 1)
