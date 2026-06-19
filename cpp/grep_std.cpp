// cppgrep_std - idiomatic Modern C++23, single-threaded.
//
// std::filesystem::recursive_directory_iterator walk + whole-file std::ifstream
// read + std::string_view::find scan. The C++23 analogue of c/grep_std.c: no raw
// syscalls, no SIMD, no threads -- stdlib all the way, RAII throughout.
//   g++ -O2 -std=c++23 -o cppgrep_std grep_std.cpp
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
#include <cstdio>
#include <cstdlib>

namespace fs = std::filesystem;

namespace {

constexpr std::size_t BIN_PEEK = 65536;   // bytes scanned for a NUL (binary skip)

std::string g_pat;                 // pattern (lowercased when -i)
bool g_ci = false, g_multi = false;
bool g_matched = false;
std::string g_out;                 // one buffered output stream, flushed at exit

constexpr char lower(char c) noexcept { return (c >= 'A' && c <= 'Z') ? char(c + 32) : c; }

// Whole-file read. Returns the owning buffer + valid length, or an error we
// silently skip on (unreadable / empty / vanished file) via std::expected.
// NB: std::make_unique_for_overwrite (C++20), NOT vector::resize -- resize
// value-initializes (a full-buffer memset to 0) and then read() overwrites every
// byte, so the idiomatic `vector` would write each file's bytes twice. The
// for_overwrite allocation skips that zero-fill (measured ~46% of this program's
// user CPU on -i scans; see docs/RESULTS.md).
std::expected<std::pair<std::unique_ptr<char[]>, std::size_t>, std::errc>
read_file(const fs::path& path) {
    std::error_code ec;
    auto sz = fs::file_size(path, ec);
    if (ec || sz == 0) return std::unexpected(std::errc::io_error);
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::unexpected(std::errc::io_error);
    auto buf = std::make_unique_for_overwrite<char[]>(sz);   // no zero-fill
    in.read(buf.get(), static_cast<std::streamsize>(sz));
    return std::pair{std::move(buf), static_cast<std::size_t>(in.gcount())};
}

void search_file(const fs::path& path) {
    auto r = read_file(path);          // fresh allocation per file (idiomatic)
    if (!r) return;
    auto& [buf, len] = *r;
    if (len == 0) return;
    std::string_view hay(buf.get(), len);

    // binary skip: a NUL byte anywhere in the first 64 KB
    if (hay.substr(0, std::min(hay.size(), BIN_PEEK)).find('\0') != std::string_view::npos)
        return;

    std::string lowered;
    std::string_view scan = hay;
    if (g_ci) {
        // resize_and_overwrite (C++23): lowercase in one pass, again skipping the
        // zero-fill a plain resize() would do before the transform overwrites it.
        lowered.resize_and_overwrite(hay.size(), [&](char* p, std::size_t n) {
            for (std::size_t k = 0; k < n; ++k) p[k] = lower(hay[k]);
            return n;
        });
        scan = lowered;                // offsets are 1:1 with hay, so line bounds use hay
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
        g_matched = true;
        std::string_view line = hay.substr(ls, le - ls);
        if (g_multi) std::format_to(std::back_inserter(g_out), "{}:{}\n", path_str, line);
        else         std::format_to(std::back_inserter(g_out), "{}\n", line);
        pos = le + 1;
    }
}

[[noreturn]] void usage() {
    std::print(stderr, "usage: cppgrep_std [-r] [-i] PATTERN PATH...\n");
    std::exit(2);
}

} // namespace

int main(int argc, char** argv) {
    std::span<char*> args(argv + 1, argc > 0 ? static_cast<std::size_t>(argc - 1) : 0);
    bool recurse = false, no_more = false, have_pat = false;
    std::vector<fs::path> paths;
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
        else paths.emplace_back(a);
    }
    if (!have_pat || paths.empty()) usage();
    if (g_ci) std::ranges::transform(g_pat, g_pat.begin(), lower);
    g_multi = recurse || paths.size() > 1;

    g_out.reserve(1 << 20);
    for (const auto& p : paths) {
        std::error_code ec;
        auto st = fs::status(p, ec);
        if (ec) continue;
        if (fs::is_directory(st)) {
            if (!recurse) continue;
            std::error_code wec;
            const fs::recursive_directory_iterator end;
            for (fs::recursive_directory_iterator it(p, fs::directory_options::skip_permission_denied, wec);
                 it != end; it.increment(wec)) {
                if (wec) break;
                std::error_code fec;
                if (it->is_symlink(fec)) continue;          // grep -r: don't follow symlinks
                if (it->is_regular_file(fec)) search_file(it->path());
            }
        } else if (fs::is_regular_file(st)) {
            search_file(p);
        }
    }
    std::print("{}", g_out);
    return g_matched ? 0 : 1;
}
