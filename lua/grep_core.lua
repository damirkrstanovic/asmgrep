-- grep_core - shared logic for the LuaJIT grep variants.
--
-- LuaJIT is a *dynamic* language, but a trace-compiling JIT. The scan hot loop
-- (string.find with plain=true -> a C memmem-equivalent) and the FFI directory
-- walk are what we care about. No stdlib dir API exists in Lua, so we declare
-- POSIX opendir/readdir/closedir/lstat via the FFI and call them directly.
--
-- This module returns a table of building blocks; the three entry scripts
-- (grep_std / grep_mt / grep_mt_tuned) wire them together.

local ffi  = require("ffi")
local C    = ffi.C
local band = require("bit").band

ffi.cdef[[
typedef struct __dirstream DIR;
struct dirent {
    unsigned long  d_ino;
    long           d_off;
    unsigned short d_reclen;
    unsigned char  d_type;
    char           d_name[256];
};
DIR           *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int            closedir(DIR *dirp);

/* stat: we only need st_mode; use a generously-sized opaque buffer and pull
   st_mode out via a glibc-compatible offset. To stay portable across the
   struct-stat layout we instead use the __xstat trick is fragile -- so we
   rely on stat()/lstat() filling a buffer and we read st_mode from a known
   glibc x86-64 layout. Offsets for x86-64 glibc: st_mode @ 24 (mode_t,uint). */
typedef struct { char _pad[144]; } stat_buf;
int  lstat(const char *path, stat_buf *buf);
int  stat(const char *path, stat_buf *buf);
]]

-- DT_* values from <dirent.h>
local DT_UNKNOWN = 0
local DT_DIR     = 4
local DT_REG     = 8
local DT_LNK     = 10

-- st_mode bits / offset (x86-64 glibc struct stat: st_mode is a uint @ 24)
local S_IFMT  = 0xF000
local S_IFDIR = 0x4000
local S_IFREG = 0x8000
local S_IFLNK = 0xA000
local ST_MODE_OFF = 24

local function st_mode(buf)
    return ffi.cast("unsigned int*", ffi.cast("char*", buf) + ST_MODE_OFF)[0]
end

-- ASCII lowercase for -i. string.lower is the fast C path and only touches
-- A-Z (ASCII), which is exactly grep's -i behaviour for this experiment.
local function ascii_lower(s)
    return s:lower()
end

-- ---------------------------------------------------------------------------
-- search one in-memory buffer. Emits matching lines via `emit(path, line)`.
-- Returns true if any line matched. Mirrors c/grep_std.c line semantics:
--   * NUL in first 64KB => binary, skip (caller checks before calling).
--   * each matching line printed once; scan continues past the line.
-- ---------------------------------------------------------------------------
local function scan(data, pat, ci, path, multi, emit)
    local rd = #data
    if rd == 0 then return false end
    local hay = data
    local needle = pat
    if ci then
        hay = ascii_lower(data)
        needle = pat            -- caller passes already-lowered pat when ci
    end
    local matched = false
    local pos = 1
    local find = string.find
    while pos <= rd do
        local s = find(hay, needle, pos, true)      -- plain=true => LITERAL
        if not s then break end
        -- line bounds in the ORIGINAL data around the line CONTAINING byte s.
        -- Anchor on the match START so a zero-width (empty needle) match still
        -- selects its full line, matching grep -F "".
        local ls = s
        while ls > 1 and data:byte(ls - 1) ~= 10 do ls = ls - 1 end
        local le = s
        if le > rd then le = rd end
        while le < rd and data:byte(le) ~= 10 do le = le + 1 end
        -- le now points at the '\n' (or rd+? ) -- trim the newline off the line.
        local line_end = le
        if line_end <= rd and data:byte(line_end) == 10 then line_end = le - 1 end
        matched = true
        emit(path, data:sub(ls, line_end), multi)
        pos = le + 1            -- continue at the char after the line's '\n'
        if pos <= s then pos = s + 1 end       -- guarantee progress (empty needle)
    end
    return matched
end

-- ---------------------------------------------------------------------------
-- binary-skip check on a prefix (first 64KB): NUL byte => binary.
-- ---------------------------------------------------------------------------
local function is_binary(prefix)
    return prefix:find("\0", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- recursive directory walk via FFI. Calls visit(path) for every regular file.
-- Skips symlinks (FTW_PHYS-equivalent): uses d_type when available, falls back
-- to lstat. Does not follow symlinks into dirs.
-- ---------------------------------------------------------------------------
local function walk(root, visit)
    local d = C.opendir(root)
    if d == nil then return end
    while true do
        local ent = C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            local path = root .. "/" .. name
            local t = ent.d_type
            if t == DT_UNKNOWN then
                -- filesystem didn't fill d_type: lstat to classify.
                local sb = ffi.new("stat_buf")
                if C.lstat(path, sb) == 0 then
                    local m = band(st_mode(sb), S_IFMT)
                    if m == S_IFDIR then t = DT_DIR
                    elseif m == S_IFREG then t = DT_REG
                    elseif m == S_IFLNK then t = DT_LNK
                    else t = -1 end
                end
            end
            if t == DT_DIR then
                walk(path, visit)
            elseif t == DT_REG then
                visit(path)
            end
            -- DT_LNK and others: skipped (no symlink following)
        end
    end
    C.closedir(d)
end

-- ---------------------------------------------------------------------------
-- classify a top-level PATH arg: "dir", "file", or nil. Uses stat (follows
-- symlinks for the explicit args, matching grep's treatment of named paths).
-- ---------------------------------------------------------------------------
local function classify(path)
    local sb = ffi.new("stat_buf")
    if C.stat(path, sb) ~= 0 then return nil end
    local m = band(st_mode(sb), S_IFMT)
    if m == S_IFDIR then return "dir"
    elseif m == S_IFREG then return "file"
    else return nil end
end

-- ---------------------------------------------------------------------------
-- parse argv: returns pat, paths[], ci, r  (or nil + error on bad usage).
-- mirrors the C getopt-ish loop: -i, -r, -- ends options.
-- ---------------------------------------------------------------------------
local function parse_args(argv)
    local pat, paths, ci, r = nil, {}, false, false
    local no_more = false
    local i = 1
    local n = #argv
    while i <= n do
        local a = argv[i]
        if (not no_more) and a:sub(1,1) == "-" and #a > 1 then
            if a == "--" then
                no_more = true
            else
                for j = 2, #a do
                    local c = a:sub(j, j)
                    if c == "i" then ci = true
                    elseif c == "r" then r = true
                    else return nil end
                end
            end
        elseif pat == nil then
            pat = a
        else
            paths[#paths + 1] = a
        end
        i = i + 1
    end
    if pat == nil or #paths == 0 then return nil end
    return pat, paths, ci, r
end

return {
    ffi        = ffi,
    scan       = scan,
    is_binary  = is_binary,
    walk       = walk,
    classify   = classify,
    parse_args = parse_args,
    ascii_lower= ascii_lower,
}
