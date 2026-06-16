// zgrep - the same program as asm/grep.s and c/grep.c, in Zig, for the
// "does the language matter?" experiment. Same logic: raw Linux syscalls,
// read() small files into a reused buffer (mmap for large), binary-file skip,
// rare-byte two-byte @Vector filter, parallel directory work-queue walker.
//
//   zig build-exe -O ReleaseFast zig/grep.zig
const std = @import("std");
const linux = std.os.linux;

const BIN_PEEK = 65536;
const READBUF_SZ = 262144;
const OUTBUF_SZ = 65536;
const MAX_THREADS = 16;
const ARENA_SZ = 128 * 1024 * 1024;
const MAX_DIRS = 1 << 20;

const freq = [256]u8{
    1,1,1,1,1,1,1,1,1,1,250,1,1,1,1,1,  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    255,1,50,1,1,1,1,1,50,50,1,1,50,50,50,50, 60,60,60,60,60,60,60,60,60,60,50,1,1,50,1,1,
    1,66,33,45,50,80,38,36,58,63,20,23,48,41,61,65, 35,20,56,60,70,43,26,40,20,36,20,1,1,1,1,50,
    1,200,100,135,150,240,115,110,175,190,45,70,145,125,185,195, 105,38,170,180,210,130,80,120,40,108,35,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
};

// pattern state (read-only after prep)
var g_pat: []const u8 = "";
var g_cmp: []const u8 = "";
var g_lc: [1 << 16]u8 = undefined;
var g_patlen: usize = 0;
var g_i = false;
var g_r = false;
var g_multi = false;
var g_fold = false;
var g_off_a: usize = 0;
var g_off_b: usize = 0;
var g_a0: u8 = 0;
var g_a1: u8 = 0;
var g_b0: u8 = 0;
var g_b1: u8 = 0;
var g_single = false;

var g_match = std.atomic.Value(u8).init(0);
var g_err = std.atomic.Value(u8).init(0);

inline fn fold(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn prep() void {
    g_patlen = g_pat.len;
    g_fold = g_i;
    if (g_i) {
        for (g_pat, 0..) |c, k| g_lc[k] = fold(c);
        g_cmp = g_lc[0..g_patlen];
    } else g_cmp = g_pat;
    if (g_patlen == 0) return;
    var a: usize = 0;
    var br: u16 = 256;
    for (g_cmp, 0..) |c, k| {
        if (freq[c] < br) { br = freq[c]; a = k; }
    }
    g_off_a = a;
    g_off_b = a;
    if (g_patlen >= 2) {
        var b: usize = 0;
        var br2: u16 = 256;
        var found = false;
        for (g_cmp, 0..) |c, k| {
            if (k == a) continue;
            if (!found or freq[c] < br2) { br2 = freq[c]; b = k; found = true; }
        }
        if (g_off_a > b) { g_off_b = g_off_a; g_off_a = b; } else g_off_b = b;
    }
    g_a0 = g_cmp[g_off_a];
    g_a1 = if (g_i and g_a0 >= 'a' and g_a0 <= 'z') g_a0 - 32 else g_a0;
    g_b0 = g_cmp[g_off_b];
    g_b1 = if (g_i and g_b0 >= 'a' and g_b0 <= 'z') g_b0 - 32 else g_b0;
    g_single = (g_patlen < 2) or (freq[g_a0] <= 64);
}

fn verify(buf: []const u8, start: usize) bool {
    if (!g_fold) return std.mem.eql(u8, buf[start .. start + g_patlen], g_cmp);
    var k: usize = 0;
    while (k < g_patlen) : (k += 1) if (fold(buf[start + k]) != g_cmp[k]) return false;
    return true;
}

const V = @Vector(32, u8);

fn fmTwo(buf: []const u8, floor: usize) ?usize {
    const A0: V = @splat(g_a0);
    const A1: V = @splat(g_a1);
    const B0: V = @splat(g_b0);
    const B1: V = @splat(g_b1);
    const dd = g_off_b - g_off_a;
    var p = floor;
    while (p + 32 + dd <= buf.len) : (p += 32) {
        const va: V = buf[p..][0..32].*;
        const vb: V = buf[p + dd ..][0..32].*;
        const amask: u32 = @as(u32, @bitCast(va == A0)) | @as(u32, @bitCast(va == A1));
        const bmask: u32 = @as(u32, @bitCast(vb == B0)) | @as(u32, @bitCast(vb == B1));
        var cand: u32 = amask & bmask;
        while (cand != 0) {
            const k = @ctz(cand);
            const apos = p + k;
            if (apos >= g_off_a) {
                const start = apos - g_off_a;
                if (start >= floor and start + g_patlen <= buf.len and verify(buf, start)) return start;
            }
            cand &= cand - 1;
        }
    }
    while (p < buf.len) : (p += 1) {
        const c = buf[p];
        if (c != g_a0 and c != g_a1) continue;
        if (p < g_off_a) continue;
        const start = p - g_off_a;
        if (start < floor or start + g_patlen > buf.len) continue;
        var hb = buf[start + g_off_b];
        if (g_fold) hb = fold(hb);
        if (hb != g_cmp[g_off_b]) continue;
        if (verify(buf, start)) return start;
    }
    return null;
}

fn fmSingle(buf: []const u8, floor: usize) ?usize {
    var p = floor;
    while (p < buf.len) {
        const rel = blk: {
            const x = std.mem.indexOfScalar(u8, buf[p..], g_a0);
            if (!g_i) break :blk x;
            const y = std.mem.indexOfScalar(u8, buf[p..], g_a1);
            if (x == null) break :blk y;
            if (y == null) break :blk x;
            break :blk @min(x.?, y.?);
        };
        if (rel == null) return null;
        const hit = p + rel.?;
        if (hit < g_off_a) { p = hit + 1; continue; }
        const start = hit - g_off_a;
        if (start < floor) { p = hit + 1; continue; }
        if (start + g_patlen > buf.len) return null;
        if (verify(buf, start)) return start;
        p = hit + 1;
    }
    return null;
}

// ---- per-thread context ----
const Ctx = struct {
    rbuf: []u8,
    obuf: []u8,
    olen: usize = 0,
};

// plain atomic spinlock (same idea as the asm; avoids std.Io.Mutex's Io param)
const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn lock(s: *SpinLock) void {
        while (s.state.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(s: *SpinLock) void {
        s.state.store(0, .release);
    }
};
var g_outlock: SpinLock = .{};

fn flushCtx(c: *Ctx) void {
    if (c.olen == 0) return;
    g_outlock.lock();
    _ = linux.write(1, c.obuf.ptr, c.olen);
    g_outlock.unlock();
    c.olen = 0;
}

fn emit(c: *Ctx, path: []const u8, line: []const u8) void {
    g_match.store(1, .monotonic);
    const need = line.len + 1 + (if (g_multi) path.len + 1 else 0);
    if (need > OUTBUF_SZ) {
        g_outlock.lock();
        if (g_multi) { _ = linux.write(1, path.ptr, path.len); _ = linux.write(1, ":", 1); }
        _ = linux.write(1, line.ptr, line.len);
        _ = linux.write(1, "\n", 1);
        g_outlock.unlock();
        return;
    }
    if (c.olen + need > OUTBUF_SZ) flushCtx(c);
    var o = c.olen;
    if (g_multi) {
        @memcpy(c.obuf[o .. o + path.len], path);
        o += path.len;
        c.obuf[o] = ':';
        o += 1;
    }
    @memcpy(c.obuf[o .. o + line.len], line);
    o += line.len;
    c.obuf[o] = '\n';
    o += 1;
    c.olen = o;
}

fn scan(c: *Ctx, buf: []const u8, path: []const u8) void {
    const peek = @min(buf.len, BIN_PEEK);
    if (std.mem.indexOfScalar(u8, buf[0..peek], 0) != null) return; // binary
    if (g_patlen == 0) {
        var p: usize = 0;
        while (p < buf.len) {
            const nl = std.mem.indexOfScalar(u8, buf[p..], '\n');
            const le = if (nl) |i| p + i else buf.len;
            emit(c, path, buf[p..le]);
            if (nl == null) break;
            p = le + 1;
        }
        return;
    }
    var p: usize = 0;
    while (p < buf.len) {
        const m = if (g_single) fmSingle(buf, p) else fmTwo(buf, p);
        if (m == null) break;
        const start = m.?;
        const ls = if (std.mem.lastIndexOfScalar(u8, buf[0..start], '\n')) |i| i + 1 else 0;
        const le = if (std.mem.indexOfScalar(u8, buf[start..], '\n')) |i| start + i else buf.len;
        emit(c, path, buf[ls..le]);
        p = le + 1;
    }
}

fn searchFile(c: *Ctx, path: [*:0]const u8) void {
    const fd_r = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_r)) < 0) { g_err.store(1, .monotonic); return; }
    const fd: i32 = @intCast(fd_r);
    const n = linux.read(fd, c.rbuf.ptr, READBUF_SZ);
    if (@as(isize, @bitCast(n)) < 0) { _ = linux.close(fd); g_err.store(1, .monotonic); return; }
    const pslice = std.mem.span(path);
    if (n < READBUF_SZ) {
        if (n > 0) scan(c, c.rbuf[0..n], pslice);
        _ = linux.close(fd);
        return;
    }
    // large file: get size via lseek, mmap
    const sz = linux.lseek(fd, 0, 2);
    if (@as(isize, @bitCast(sz)) > 0) {
        const m = linux.mmap(null, sz, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (@as(isize, @bitCast(m)) >= 0) {
            const base: [*]const u8 = @ptrFromInt(m);
            scan(c, base[0..sz], pslice);
            _ = linux.munmap(@ptrFromInt(m), sz);
        }
    }
    _ = linux.close(fd);
}

// ---- directory work queue ----
var arena: [ARENA_SZ]u8 = undefined;
var arena_off = std.atomic.Value(usize).init(0);
var g_q: [MAX_DIRS][]const u8 = undefined;
var g_qtop: usize = 0;
var g_qlock: SpinLock = .{};
var g_pending = std.atomic.Value(i64).init(0);

fn qPush(path: []const u8) void {
    const need = path.len + 1; // + NUL for open()
    const off = arena_off.fetchAdd(need, .monotonic);
    if (off + need > ARENA_SZ) return;
    @memcpy(arena[off .. off + path.len], path);
    arena[off + path.len] = 0;
    g_qlock.lock();
    if (g_qtop < MAX_DIRS) {
        g_q[g_qtop] = arena[off .. off + path.len];
        g_qtop += 1;
        _ = g_pending.fetchAdd(1, .monotonic);
    }
    g_qlock.unlock();
}
fn qPop() ?[]const u8 {
    g_qlock.lock();
    defer g_qlock.unlock();
    if (g_qtop == 0) return null;
    g_qtop -= 1;
    return g_q[g_qtop];
}

fn traverse(c: *Ctx, dir: []const u8) void {
    var dbuf: [4096]u8 = undefined;
    @memcpy(dbuf[0..dir.len], dir);
    dbuf[dir.len] = 0;
    const dpath: [*:0]const u8 = @ptrCast(&dbuf);
    const fd_r = linux.open(dpath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(fd_r)) < 0) return;
    const fd: i32 = @intCast(fd_r);
    defer _ = linux.close(fd);
    var dents: [8192]u8 = undefined;
    var child: [4096]u8 = undefined;
    @memcpy(child[0..dir.len], dir);
    child[dir.len] = '/';
    const base_len = dir.len + 1;
    while (true) {
        const nb = linux.getdents64(fd, &dents, dents.len);
        if (@as(isize, @bitCast(nb)) <= 0) break;
        var off: usize = 0;
        while (off < nb) {
            const reclen = std.mem.readInt(u16, dents[off + 16 ..][0..2], .little);
            const dtype = dents[off + 18];
            const name_ptr = @as([*:0]const u8, @ptrCast(&dents[off + 19]));
            const name = std.mem.span(name_ptr);
            off += reclen;
            if (name.len == 0) continue;
            if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;
            if (dtype == 10) continue; // DT_LNK
            if (base_len + name.len + 1 > child.len) continue;
            @memcpy(child[base_len .. base_len + name.len], name);
            child[base_len + name.len] = 0;
            const cslice = child[0 .. base_len + name.len];
            const cz: [*:0]const u8 = @ptrCast(&child);
            if (dtype == 4) { // DT_DIR
                if (g_r) qPush(cslice);
            } else if (dtype == 8) { // DT_REG
                searchFile(c, cz);
            } else if (dtype == 0) { // DT_UNKNOWN -> statx
                var st: linux.Statx = undefined;
                if (@as(isize, @bitCast(linux.statx(linux.AT.FDCWD, cz, 0, .{ .TYPE = true }, &st))) == 0) {
                    const m = st.mode & 0o170000;
                    if (m == 0o040000) { if (g_r) qPush(cslice); } else if (m == 0o100000) searchFile(c, cz);
                }
            }
        }
    }
}

fn worker(c: *Ctx) void {
    while (true) {
        if (qPop()) |d| {
            traverse(c, d);
            _ = g_pending.fetchSub(1, .monotonic);
        } else {
            if (g_pending.load(.monotonic) == 0) break;
            std.Thread.yield() catch {};
        }
    }
    flushCtx(c);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var no_more = false;
    var npaths: usize = 0;
    for (args[1..]) |az| {
        const a = std.mem.span(az);
        if (!no_more and a.len >= 1 and a[0] == '-' and a.len >= 2) {
            if (a.len == 2 and a[1] == '-') { no_more = true; continue; }
            for (a[1..]) |ch| {
                if (ch == 'i') g_i = true else if (ch == 'r') g_r = true else {
                    _ = linux.write(2, "usage: zgrep [-r] [-i] PATTERN PATH...\n", 38);
                    return 2;
                }
            }
        } else {
            if (g_pat.len == 0) g_pat = a else npaths += 1;
        }
    }
    if (g_pat.len == 0 or npaths == 0) {
        _ = linux.write(2, "usage: zgrep [-r] [-i] PATTERN PATH...\n", 38);
        return 2;
    }
    g_multi = g_r or npaths > 1;
    prep();

    var nt: usize = std.Thread.getCpuCount() catch 1;
    if (nt < 1) nt = 1;
    if (nt > MAX_THREADS) nt = MAX_THREADS;

    var ctxs: [MAX_THREADS]Ctx = undefined;
    const alloc = std.heap.page_allocator;
    for (0..nt) |t| {
        ctxs[t] = .{ .rbuf = alloc.alloc(u8, READBUF_SZ) catch unreachable, .obuf = alloc.alloc(u8, OUTBUF_SZ) catch unreachable };
    }

    // pass 2: roots
    no_more = false;
    var pat_seen = false;
    for (args[1..]) |az| {
        const a = std.mem.span(az);
        if (!no_more and a.len >= 2 and a[0] == '-') {
            if (a.len == 2 and a[1] == '-') no_more = true;
            continue;
        }
        if (!pat_seen) { pat_seen = true; continue; }
        var st: linux.Statx = undefined;
        if (@as(isize, @bitCast(linux.statx(linux.AT.FDCWD, az, 0, .{ .TYPE = true }, &st))) != 0) { g_err.store(1, .monotonic); continue; }
        const m = st.mode & 0o170000;
        if (m == 0o040000) { if (g_r) qPush(a); } else if (m == 0o100000) searchFile(&ctxs[0], az);
    }

    if (g_pending.load(.monotonic) > 0) {
        var threads: [MAX_THREADS]std.Thread = undefined;
        var spawned: usize = 0;
        var t: usize = 1;
        while (t < nt) : (t += 1) {
            threads[t] = std.Thread.spawn(.{}, worker, .{&ctxs[t]}) catch break;
            spawned += 1;
        }
        worker(&ctxs[0]);
        var j: usize = 0;
        while (j < spawned) : (j += 1) threads[j + 1].join();
    } else {
        flushCtx(&ctxs[0]);
    }

    if (g_err.load(.monotonic) != 0) return 2;
    return if (g_match.load(.monotonic) != 0) 0 else 1;
}
