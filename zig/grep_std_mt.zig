// zgrep_std_mt - idiomatic Zig, multithreaded: collect the file list with
// std.Io.Dir.walk, then a std.Thread pool reads (readFileAlloc) and searches
// (std.mem.findPos / std.ascii.findIgnoreCasePos) in parallel.
const std = @import("std");
const linux = std.os.linux;

const ARENA_SZ = 128 * 1024 * 1024;
const MAX_FILES = 1 << 20;
const MAX_THREADS = 16;

var g_pat: []const u8 = "";
var g_ci = false;
var g_r = false;
var g_multi = false;

var arena: [ARENA_SZ]u8 = undefined;
var arena_off: usize = 0;
var g_files: [MAX_FILES][]const u8 = undefined;
var g_nfiles: usize = 0;

const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn lock(s: *SpinLock) void {
        while (s.state.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(s: *SpinLock) void {
        s.state.store(0, .release);
    }
};

const Shared = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    outlock: SpinLock = .{},
    matched: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
};

fn store(path: []const u8) void {
    if (g_nfiles >= MAX_FILES or arena_off + path.len > ARENA_SZ) return;
    @memcpy(arena[arena_off..][0..path.len], path);
    g_files[g_nfiles] = arena[arena_off..][0..path.len];
    arena_off += path.len;
    g_nfiles += 1;
}

fn emit(sh: *Shared, obuf: []u8, olen: *usize, path: []const u8, line: []const u8) void {
    sh.matched.store(1, .monotonic);
    const need = (if (g_multi) path.len + 1 else 0) + line.len + 1;
    if (need > obuf.len) {
        sh.outlock.lock();
        if (g_multi) { _ = linux.write(1, path.ptr, path.len); _ = linux.write(1, ":", 1); }
        _ = linux.write(1, line.ptr, line.len);
        _ = linux.write(1, "\n", 1);
        sh.outlock.unlock();
        return;
    }
    if (olen.* + need > obuf.len) flush(sh, obuf, olen);
    var o = olen.*;
    if (g_multi) {
        @memcpy(obuf[o..][0..path.len], path);
        o += path.len;
        obuf[o] = ':';
        o += 1;
    }
    @memcpy(obuf[o..][0..line.len], line);
    o += line.len;
    obuf[o] = '\n';
    o += 1;
    olen.* = o;
}
fn flush(sh: *Shared, obuf: []u8, olen: *usize) void {
    if (olen.* == 0) return;
    sh.outlock.lock();
    _ = linux.write(1, obuf.ptr, olen.*);
    sh.outlock.unlock();
    olen.* = 0;
}

fn searchData(sh: *Shared, obuf: []u8, olen: *usize, data: []const u8, path: []const u8) void {
    const peek = @min(data.len, 65536);
    if (std.mem.findScalar(u8, data[0..peek], 0) != null) return;
    if (g_pat.len == 0) return;
    var pos: usize = 0;
    while (pos <= data.len) {
        const m = if (g_ci) std.ascii.findIgnoreCasePos(data, pos, g_pat) else std.mem.findPos(u8, data, pos, g_pat);
        const at = m orelse break;
        const ls = if (std.mem.findScalarLast(u8, data[0..at], '\n')) |i| i + 1 else 0;
        const le = std.mem.findScalarPos(u8, data, at, '\n') orelse data.len;
        emit(sh, obuf, olen, path, data[ls..le]);
        pos = le + 1;
    }
}

fn worker(sh: *Shared) void {
    var obuf: [1 << 16]u8 = undefined;
    var olen: usize = 0;
    while (true) {
        const i = sh.idx.fetchAdd(1, .monotonic);
        if (i >= g_nfiles) break;
        const path = g_files[i];
        const data = std.Io.Dir.cwd().readFileAlloc(sh.io, path, sh.gpa, .unlimited) catch continue;
        defer sh.gpa.free(data);
        searchData(sh, &obuf, &olen, data, path);
    }
    flush(sh, &obuf, &olen);
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = init.minimal.args.vector;

    var paths_buf: [256][]const u8 = undefined;
    var np: usize = 0;
    var pat_set = false;
    var no_more = false;
    for (args[1..]) |az| {
        const a = std.mem.span(az);
        if (!no_more and a.len >= 2 and a[0] == '-') {
            if (a.len == 2 and a[1] == '-') { no_more = true; continue; }
            for (a[1..]) |c| {
                if (c == 'i') g_ci = true else if (c == 'r') g_r = true else {
                    _ = linux.write(2, "usage: zgrep_std_mt [-r] [-i] PATTERN PATH...\n", 45);
                    return 2;
                }
            }
        } else if (!pat_set) { g_pat = a; pat_set = true; } else if (np < paths_buf.len) { paths_buf[np] = a; np += 1; }
    }
    if (!pat_set or np == 0) {
        _ = linux.write(2, "usage: zgrep_std_mt [-r] [-i] PATTERN PATH...\n", 45);
        return 2;
    }
    g_multi = g_r or np > 1;

    // collect file list (single-threaded walk)
    var pbuf: [4096]u8 = undefined;
    for (paths_buf[0..np]) |p| {
        var dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch {
            store(p);
            continue;
        };
        defer dir.close(io);
        if (!g_r) continue;
        var walker = dir.walk(gpa) catch continue;
        defer walker.deinit();
        while (true) {
            const entry = (walker.next(io) catch break) orelse break;
            if (entry.kind != .file) continue;
            if (p.len + 1 + entry.path.len > pbuf.len) continue;
            @memcpy(pbuf[0..p.len], p);
            pbuf[p.len] = '/';
            @memcpy(pbuf[p.len + 1 ..][0..entry.path.len], entry.path);
            store(pbuf[0 .. p.len + 1 + entry.path.len]);
        }
    }

    var sh = Shared{ .io = io, .gpa = gpa };
    var nt: usize = std.Thread.getCpuCount() catch 1;
    if (nt > MAX_THREADS) nt = MAX_THREADS;
    if (nt < 1) nt = 1;
    var threads: [MAX_THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    var t: usize = 1;
    while (t < nt) : (t += 1) {
        threads[t] = std.Thread.spawn(.{}, worker, .{&sh}) catch break;
        spawned += 1;
    }
    worker(&sh);
    var j: usize = 0;
    while (j < spawned) : (j += 1) threads[j + 1].join();

    return if (sh.matched.load(.monotonic) != 0) 0 else 1;
}
