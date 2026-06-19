// cppgrep_std_mt_tuned - idiomatic Modern C++23, multithreading + the two memory
// pillars that make threads actually scale:
//   (a) ONE per-thread buffer, grown to the largest file and reused (never freed
//       between files) -- so the kernel doesn't fault in fresh pages every read;
//   (b) read a 64 KB prefix first, binary-check it, and read the rest ONLY if the
//       file isn't binary -- so a 291 MB .git pack is never faulted in then skipped.
// Same idiomatic stdlib otherwise (recursive_directory_iterator, string_view::find,
// jthread pool). This is the variant that goes past grep.
//   g++ -O2 -std=c++23 -pthread -o cppgrep_std_mt_tuned grep_mt_tuned.cpp
#include <print>
#include <format>
#include <string>
#include <string_view>
#include <vector>
#include <span>
#include <expected>
#include <ranges>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <thread>
#include <atomic>
#include <mutex>
#include <cstdio>
#include <cstdlib>

namespace fs = std::filesystem;

namespace {

constexpr std::size_t BIN_PEEK = 65536;
constexpr std::size_t OUT_FLUSH = 65536;

std::string g_pat;
bool g_ci = false, g_multi = false;

std::vector<fs::path> g_files;
std::atomic<std::size_t> g_idx{0};
std::atomic<bool> g_matched{false};
std::mutex g_outmtx;

constexpr char lower(char c) noexcept { return (c >= 'A' && c <= 'Z') ? char(c + 32) : c; }

void flush(std::string& out) {
    if (out.empty()) return;
    std::scoped_lock lk(g_outmtx);
    std::fwrite(out.data(), 1, out.size(), stdout);
    out.clear();
}

// Prefix-first read into a REUSED buffer. rbuf only ever grows (resize up); once a
// thread has seen its largest file, later reads hit no allocation and no fault.
// Returns std::unexpected for skip (unreadable / empty / binary).
std::expected<std::span<const char>, std::errc>
read_tuned(const fs::path& path, std::vector<char>& rbuf) {
    std::error_code ec;
    auto sz = fs::file_size(path, ec);
    if (ec || sz == 0) return std::unexpected(std::errc::io_error);
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::unexpected(std::errc::io_error);

    std::size_t peek = std::min<std::size_t>(sz, BIN_PEEK);
    if (rbuf.size() < peek) rbuf.resize(peek);
    in.read(rbuf.data(), static_cast<std::streamsize>(peek));
    std::size_t got = static_cast<std::size_t>(in.gcount());
    // binary: NUL in the prefix -> skip, and the rest of the file stays unread
    if (std::string_view(rbuf.data(), got).find('\0') != std::string_view::npos)
        return std::unexpected(std::errc::io_error);
    if (sz > got) {
        if (rbuf.size() < sz) rbuf.resize(sz);
        in.read(rbuf.data() + got, static_cast<std::streamsize>(sz - got));
        got += static_cast<std::size_t>(in.gcount());
    }
    return std::span<const char>(rbuf.data(), got);
}

// rbuf and lbuf are per-thread, reused across files (the tuned memory pillar).
void search_file(const fs::path& path, std::string& out,
                 std::vector<char>& rbuf, std::string& lbuf) {
    auto r = read_tuned(path, rbuf);
    if (!r || r->empty()) return;
    std::string_view hay(r->data(), r->size());   // prefix binary-check already done

    std::string_view scan = hay;
    if (g_ci) {
        if (lbuf.size() < hay.size()) lbuf.resize(hay.size());
        std::ranges::transform(hay, lbuf.begin(), lower);
        scan = std::string_view(lbuf.data(), hay.size());
    }

    const std::string path_str = g_multi ? path.string() : std::string();
    std::size_t pos = 0;
    while (pos < scan.size()) {
        std::size_t m = scan.find(g_pat, pos);
        if (m == std::string_view::npos) break;
        std::size_t prev = (m == 0) ? std::string_view::npos : hay.rfind('\n', m - 1);
        std::size_t ls = (prev == std::string_view::npos) ? 0 : prev + 1;
        std::size_t nl = hay.find('\n', m);
        std::size_t le = (nl == std::string_view::npos) ? hay.size() : nl;
        g_matched.store(true, std::memory_order_relaxed);
        std::string_view line = hay.substr(ls, le - ls);
        if (g_multi) std::format_to(std::back_inserter(out), "{}:{}\n", path_str, line);
        else         std::format_to(std::back_inserter(out), "{}\n", line);
        pos = le + 1;
    }
}

void worker() {
    std::string out;
    out.reserve(OUT_FLUSH);
    std::vector<char> rbuf;   // reused across every file this thread handles
    std::string lbuf;         // reused lowercased haystack (only grows)
    for (;;) {
        std::size_t i = g_idx.fetch_add(1, std::memory_order_relaxed);
        if (i >= g_files.size()) break;
        search_file(g_files[i], out, rbuf, lbuf);
        if (out.size() >= OUT_FLUSH) flush(out);
    }
    flush(out);
}

void collect(const fs::path& dir) {
    std::error_code wec;
    const fs::recursive_directory_iterator end;
    for (fs::recursive_directory_iterator it(dir, fs::directory_options::skip_permission_denied, wec);
         it != end; it.increment(wec)) {
        if (wec) break;
        std::error_code fec;
        if (it->is_symlink(fec)) continue;
        if (it->is_regular_file(fec)) g_files.push_back(it->path());
    }
}

[[noreturn]] void usage() {
    std::print(stderr, "usage: cppgrep_std_mt_tuned [-r] [-i] PATTERN PATH...\n");
    std::exit(2);
}

} // namespace

int main(int argc, char** argv) {
    std::span<char*> args(argv + 1, argc > 0 ? static_cast<std::size_t>(argc - 1) : 0);
    bool recurse = false, no_more = false, have_pat = false;
    std::vector<fs::path> roots;
    for (char* a : args) {
        std::string_view s = a;
        if (!no_more && s.size() >= 2 && s[0] == '-') {
            if (s == "--") { no_more = true; continue; }
            for (char c : s.substr(1)) {
                if (c == 'i') g_ci = true;
                else if (c == 'r') recurse = true;
                else usage();
            }
        } else if (!have_pat) { g_pat = a; have_pat = true; }
        else roots.emplace_back(a);
    }
    if (!have_pat || roots.empty()) usage();
    if (g_ci) std::ranges::transform(g_pat, g_pat.begin(), lower);
    g_multi = recurse || roots.size() > 1;

    for (const auto& p : roots) {
        std::error_code ec;
        auto st = fs::status(p, ec);
        if (ec) continue;
        if (fs::is_directory(st)) { if (recurse) collect(p); }
        else if (fs::is_regular_file(st)) g_files.push_back(p);
    }

    unsigned nt = std::thread::hardware_concurrency();
    if (nt < 1) nt = 1;
    if (nt > 16) nt = 16;
    {
        std::vector<std::jthread> pool;
        pool.reserve(nt - 1);
        for (unsigned t = 0; t + 1 < nt; ++t) pool.emplace_back(worker);
        worker();
    }

    return g_matched.load() ? 0 : 1;
}
