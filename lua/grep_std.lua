#!/usr/bin/env luajit
-- ljgrep_std - idiomatic single-threaded LuaJIT grep.
--   FFI POSIX dir walk + whole-file io.read('*a') + string.find(plain=true).
-- Mirrors c/grep_std.c semantics. Single process by nature (LuaJIT has no
-- threads); _std is the headline single-thread scan number.
package.path = (arg[0]:match("^(.*/)") or "./") .. "?.lua;" .. package.path
local core = require("grep_core")

local pat, paths, ci, r = core.parse_args(arg)
if not pat then
    io.stderr:write("usage: ljgrep_std [-r] [-i] PATTERN PATH...\n")
    os.exit(2)
end

local multi = r or #paths > 1
local needle = ci and core.ascii_lower(pat) or pat

-- batched output: accumulate into a table, concat + single io.write at the end.
local out = {}
local nout = 0
local function emit(path, line, m)
    if m then
        nout = nout + 1; out[nout] = path
        nout = nout + 1; out[nout] = ":"
        nout = nout + 1; out[nout] = line
        nout = nout + 1; out[nout] = "\n"
    else
        nout = nout + 1; out[nout] = line
        nout = nout + 1; out[nout] = "\n"
    end
end

local matched = false
local function search_file(path)
    local f = io.open(path, "rb")
    if not f then return end
    local data = f:read("*a")
    f:close()
    if not data or #data == 0 then return end
    local peek = #data < 65536 and data or data:sub(1, 65536)
    if core.is_binary(peek) then return end          -- binary skip
    if core.scan(data, needle, ci, path, multi, emit) then matched = true end
end

for _, p in ipairs(paths) do
    local kind = core.classify(p)
    if kind == "dir" then
        if r then core.walk(p, search_file) end
    elseif kind == "file" then
        search_file(p)
    end
end

if nout > 0 then io.write(table.concat(out)) end
os.exit(matched and 0 or 1)
