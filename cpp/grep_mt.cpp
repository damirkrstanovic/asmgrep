// cppgrep_std_mt - idiomatic Modern C++23, naive multithreading.
//
// Walk collects the file list, then a std::jthread pool searches files in
// parallel (std::atomic work index). DELIBERATELY naive on memory: a fresh
// per-file buffer is allocated every read -- this is the "threads bolted onto
// allocation-heavy code" variant that, per the experiment, fails to scale
// (page-fault contention). grep_mt_tuned fixes exactly that.
//   g++ -O2 -std=c++23 -pthread -o cppgrep_std_mt grep_mt.cpp
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
#include <memory>
#include <utility>
#include <thread>
#include <atomic>
#include <mutex>
#include <cstdio>
#include <cstdlib>

namespace fs = std::filesystem;

namespace {

constexpr std::size_t BIN_PEEK = 65536;
constexpr std::size_t OUT_FLUSH = 65536;   // flush a thread's buffer past this

std::string g_pat;
bool g_ci = false, g_multi = false;

std::vector<fs::path> g_files;
std::atomic<std::size_t> g_idx{0};
std::atomic<bool> g_matched{false};
std::mutex g_outmtx;

constexpr char lower(char c) noexcept { return (c >= 'A' && c <= 'Z') ? char(c + 32) : c; }

// flush a whole per-thread buffer under the lock -- since only whole lines are
// appended, a flush can never split a line across threads.
void flush(std::string& out) {
    if (out.empty()) return;
    std::scoped_lock lk(g_outmtx);
    std::fwrite(out.data(), 1, out.size(), stdout);
    out.clear();
}

// std::make_unique_for_overwrite (C++20), NOT vector::resize: resize zero-fills
// the whole buffer before read() overwrites it (each file's bytes written twice).
// The fresh-per-file allocation is the naive memory strategy on purpose; the
// zero-fill is just wasted work and not part of that point, so we skip it.
std::expected<std::pair<std::unique_ptr<char[]>, std::size_t>, std::errc>
read_file(const fs::path& path) {
    std::error_code ec;
    auto sz = fs::file_size(path, ec);
    if (ec || sz == 0) return std::unexpected(std::errc::io_error);
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::unexpected(std::errc::io_error);
    auto buf = std::make_unique_for_overwrite<char[]>(sz);
    in.read(buf.get(), static_cast<std::streamsize>(sz));
    return std::pair{std::move(buf), static_cast<std::size_t>(in.gcount())};
}

void search_file(const fs::path& path, std::string& out) {
    auto r = read_file(path);          // fresh allocation per file (the naive part)
    if (!r) return;
    auto& [buf, len] = *r;
    if (len == 0) return;
    std::string_view hay(buf.get(), len);

    if (hay.substr(0, std::min(hay.size(), BIN_PEEK)).find('\0') != std::string_view::npos)
        return;

    std::string lowered;
    std::string_view scan = hay;
    if (g_ci) {
        lowered.resize_and_overwrite(hay.size(), [&](char* p, std::size_t n) {
            for (std::size_t k = 0; k < n; ++k) p[k] = lower(hay[k]);
            return n;
        });
        scan = lowered;
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
    for (;;) {
        std::size_t i = g_idx.fetch_add(1, std::memory_order_relaxed);
        if (i >= g_files.size()) break;
        search_file(g_files[i], out);
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
    std::print(stderr, "usage: cppgrep_std_mt [-r] [-i] PATTERN PATH...\n");
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
        worker();                      // main thread is worker 0
    }                                  // jthreads join here

    return g_matched.load() ? 0 : 1;
}
