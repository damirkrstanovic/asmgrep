// cgrep_std - idiomatic C: nftw() walk + whole-file read + memmem().
// Single-threaded, stdlib all the way (no hand-rolled syscalls/SIMD/threads).
//   cc -O2 -o cgrep_std grep_std.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <ftw.h>
#include <sys/stat.h>

static char *g_pat;
static size_t g_patlen;
static char *g_lpat;
static int g_ci, g_r, g_multi, g_matched;

static void search_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); return; }
    rewind(f);
    char *data = malloc((size_t)sz);
    if (!data) { fclose(f); return; }
    size_t rd = fread(data, 1, (size_t)sz, f);
    fclose(f);

    size_t peek = rd < 65536 ? rd : 65536;
    if (memchr(data, 0, peek)) { free(data); return; }    // binary skip

    const char *hay = data;
    const char *needle = g_pat;
    char *low = NULL;
    if (g_ci) {
        low = malloc(rd);
        if (!low) { free(data); return; }
        for (size_t k = 0; k < rd; k++) low[k] = (char)tolower((unsigned char)data[k]);
        hay = low; needle = g_lpat;
    }
    size_t pos = 0;
    while (pos < rd) {
        char *h = memmem(hay + pos, rd - pos, needle, g_patlen);
        if (!h) break;
        size_t m = (size_t)(h - hay);
        size_t ls = m; while (ls > 0 && data[ls-1] != '\n') ls--;
        size_t le = m; while (le < rd && data[le] != '\n') le++;
        g_matched = 1;
        if (g_multi) { fputs(path, stdout); putchar(':'); }
        fwrite(data + ls, 1, le - ls, stdout);
        putchar('\n');
        pos = le + 1;
    }
    free(low);
    free(data);
}

static int cb(const char *path, const struct stat *sb, int type, struct FTW *f) {
    (void)sb; (void)f;
    if (type == FTW_F) search_file(path);
    return 0;
}

static void usage(void) { fputs("usage: cgrep_std [-r] [-i] PATTERN PATH...\n", stderr); exit(2); }

int main(int argc, char **argv) {
    char **paths = malloc((size_t)argc * sizeof(char*));
    int np = 0, no_more = 0;
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];
        if (!no_more && a[0] == '-' && a[1]) {
            if (a[1] == '-' && !a[2]) { no_more = 1; continue; }
            for (char *q = a + 1; *q; q++) {
                if (*q == 'i') g_ci = 1; else if (*q == 'r') g_r = 1; else usage();
            }
        } else if (!g_pat) g_pat = a;
        else paths[np++] = a;
    }
    if (!g_pat || np == 0) usage();
    g_patlen = strlen(g_pat);
    g_lpat = malloc(g_patlen + 1);
    for (size_t k = 0; k <= g_patlen; k++) g_lpat[k] = (char)tolower((unsigned char)g_pat[k]);
    g_multi = g_r || np > 1;

    static char obuf[1 << 20];
    setvbuf(stdout, obuf, _IOFBF, sizeof obuf);

    for (int i = 0; i < np; i++) {
        struct stat st;
        if (stat(paths[i], &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            if (g_r) nftw(paths[i], cb, 32, FTW_PHYS);
        } else if (S_ISREG(st.st_mode)) {
            search_file(paths[i]);
        }
    }
    fflush(stdout);
    return g_matched ? 0 : 1;
}
