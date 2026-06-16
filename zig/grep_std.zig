// zgrep_std - idiomatic Zig 0.16: std.Io.Dir.walk + readFileAlloc +
// std.mem.findPos / std.ascii.findIgnoreCasePos. Single-threaded, stdlib all
// the way (the new std.Io interface; no hand-rolled syscalls/SIMD/threads).
//   zig build-exe -O ReleaseFast zig/grep_std.zig
const std = @import("std");
const linux = std.os.linux;

var g_pat: []const u8 = "";
var g_ci = false;
var g_r = false;
var g_multi = false;
var g_matched = false;

var obuf: [1 << 16]u8 = undefined;
var olen: usize = 0;

fn w1(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}
fn flush() void {
    if (olen > 0) { w1(obuf[0..olen]); olen = 0; }
}
fn emitLine(path: []const u8, line: []const u8) void {
    g_matched = true;
    const need = (if (g_multi) path.len + 1 else 0) + line.len + 1;
    if (need > obuf.len) {
        flush();
        if (g_multi) { w1(path); w1(":"); }
        w1(line);
        w1("\n");
        return;
    }
    if (olen + need > obuf.len) flush();
    if (g_multi) {
        @memcpy(obuf[olen..][0..path.len], path);
        olen += path.len;
        obuf[olen] = ':';
        olen += 1;
    }
    @memcpy(obuf[olen..][0..line.len], line);
    olen += line.len;
    obuf[olen] = '\n';
    olen += 1;
}

fn searchData(data: []const u8, path: []const u8) void {
    const peek = @min(data.len, 65536);
    if (std.mem.findScalar(u8, data[0..peek], 0) != null) return; // binary
    if (g_pat.len == 0) {
        var p: usize = 0;
        while (p < data.len) {
            const le = std.mem.findScalarPos(u8, data, p, '\n') orelse data.len;
            emitLine(path, data[p..le]);
            if (le == data.len) break;
            p = le + 1;
        }
        return;
    }
    var pos: usize = 0;
    while (pos <= data.len) {
        const m = if (g_ci)
            std.ascii.findIgnoreCasePos(data, pos, g_pat)
        else
            std.mem.findPos(u8, data, pos, g_pat);
        const at = m orelse break;
        const ls = if (std.mem.findScalarLast(u8, data[0..at], '\n')) |i| i + 1 else 0;
        const le = std.mem.findScalarPos(u8, data, at, '\n') orelse data.len;
        emitLine(path, data[ls..le]);
        pos = le + 1;
    }
}

fn searchNamed(io: std.Io, gpa: std.mem.Allocator, name: []const u8) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .unlimited) catch return;
    defer gpa.free(data);
    searchData(data, name);
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
                    w1("usage: zgrep_std [-r] [-i] PATTERN PATH...\n");
                    return 2;
                }
            }
        } else if (!pat_set) {
            g_pat = a;
            pat_set = true;
        } else if (np < paths_buf.len) {
            paths_buf[np] = a;
            np += 1;
        }
    }
    if (!pat_set or np == 0) {
        w1("usage: zgrep_std [-r] [-i] PATTERN PATH...\n");
        return 2;
    }
    g_multi = g_r or np > 1;

    var pbuf: [4096]u8 = undefined;
    for (paths_buf[0..np]) |p| {
        var dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch {
            searchNamed(io, gpa, p); // not a dir -> treat as file
            continue;
        };
        defer dir.close(io);
        if (!g_r) continue; // directory without -r: skip
        var walker = dir.walk(gpa) catch continue;
        defer walker.deinit();
        while (true) {
            const entry = (walker.next(io) catch break) orelse break;
            if (entry.kind != .file) continue;
            const data = dir.readFileAlloc(io, entry.path, gpa, .unlimited) catch continue;
            defer gpa.free(data);
            if (p.len + 1 + entry.path.len > pbuf.len) continue;
            @memcpy(pbuf[0..p.len], p);
            pbuf[p.len] = '/';
            @memcpy(pbuf[p.len + 1 ..][0..entry.path.len], entry.path);
            searchData(data, pbuf[0 .. p.len + 1 + entry.path.len]);
        }
    }
    flush();
    return if (g_matched) 0 else 1;
}
