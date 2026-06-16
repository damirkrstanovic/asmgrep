// cgrep_std_mt - idiomatic C, multithreaded: nftw() collects the file list,
// then a pthread pool searches files in parallel (whole-file read + memmem).
//   cc -O2 -pthread -o cgrep_std_mt grep_std_mt.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <ftw.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/stat.h>

static char *g_pat; static size_t g_patlen; static char *g_lpat;
static int g_ci, g_r, g_multi;
static atomic_int g_matched;

static char **g_files; static size_t g_nfiles, g_cap;
static atomic_size_t g_idx;
static pthread_mutex_t g_outlock = PTHREAD_MUTEX_INITIALIZER;

#define OBUF 65536
typedef struct { char buf[OBUF]; size_t len; } OB;
static void ob_flush(OB *o) {
    if (!o->len) return;
    pthread_mutex_lock(&g_outlock);
    ssize_t w = write(1, o->buf, o->len); (void)w;
    pthread_mutex_unlock(&g_outlock);
    o->len = 0;
}
// emit one whole line atomically so a buffer flush never splits a line
static void ob_line(OB *o, const char *path, const char *line, size_t llen) {
    size_t plen = g_multi ? strlen(path) : 0;
    size_t total = (g_multi ? plen + 1 : 0) + llen + 1;
    if (total > OBUF) {
        ob_flush(o);
        pthread_mutex_lock(&g_outlock);
        if (g_multi) { ssize_t w; w=write(1,path,plen);(void)w; w=write(1,":",1);(void)w; }
        ssize_t w; w=write(1,line,llen);(void)w; w=write(1,"\n",1);(void)w;
        pthread_mutex_unlock(&g_outlock);
        return;
    }
    if (o->len + total > OBUF) ob_flush(o);
    if (g_multi) { memcpy(o->buf+o->len, path, plen); o->len += plen; o->buf[o->len++] = ':'; }
    memcpy(o->buf+o->len, line, llen); o->len += llen; o->buf[o->len++] = '\n';
}

static int collect_cb(const char *path, const struct stat *sb, int type, struct FTW *f) {
    (void)sb; (void)f;
    if (type == FTW_F) {
        if (g_nfiles == g_cap) { g_cap = g_cap ? g_cap*2 : 1024; g_files = realloc(g_files, g_cap*sizeof(char*)); }
        g_files[g_nfiles++] = strdup(path);
    }
    return 0;
}

// rbuf/lbuf are per-thread, grown to the largest file seen and *reused* (never
// freed between files) so the OS doesn't fault in fresh pages every read.
static void search_file(OB *o, const char *path, char **rbuf, size_t *rcap, char **lbuf, size_t *lcap) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long szl = ftell(f);
    if (szl <= 0) { fclose(f); return; }
    rewind(f);
    size_t sz = (size_t)szl;
    // read only a prefix first, check for binary, and read the rest *only* if it
    // isn't binary -- otherwise a 291MB .git pack would be faulted in then skipped.
    size_t peek = sz < 65536 ? sz : 65536;
    if (peek > *rcap) { char *nb = realloc(*rbuf, peek); if (!nb) { fclose(f); return; } *rbuf = nb; *rcap = peek; }
    size_t got = fread(*rbuf, 1, peek, f);
    if (memchr(*rbuf, 0, got)) { fclose(f); return; }   // binary: skip, rest unread
    if (sz > got) {
        if (sz > *rcap) { char *nb = realloc(*rbuf, sz); if (!nb) { fclose(f); return; } *rbuf = nb; *rcap = sz; }
        while (got < sz) { size_t n = fread(*rbuf + got, 1, sz - got, f); if (n == 0) break; got += n; }
    }
    fclose(f);
    size_t rd = got;
    char *data = *rbuf;
    const char *hay = data; const char *needle = g_pat;
    if (g_ci) {
        if (rd > *lcap) { char *nl = realloc(*lbuf, rd); if (!nl) return; *lbuf = nl; *lcap = rd; }
        for (size_t k = 0; k < rd; k++) (*lbuf)[k] = (char)tolower((unsigned char)data[k]);
        hay = *lbuf; needle = g_lpat;
    }
    size_t pos = 0;
    while (pos < rd) {
        char *h = memmem(hay + pos, rd - pos, needle, g_patlen);
        if (!h) break;
        size_t m = (size_t)(h - hay);
        size_t ls = m; while (ls > 0 && data[ls-1] != '\n') ls--;
        size_t le = m; while (le < rd && data[le] != '\n') le++;
        atomic_store_explicit(&g_matched, 1, memory_order_relaxed);
        ob_line(o, path, data + ls, le - ls);
        pos = le + 1;
    }
}

static void *worker(void *arg) {
    (void)arg;
    OB ob; ob.len = 0;
    char *rbuf = NULL, *lbuf = NULL; size_t rcap = 0, lcap = 0;
    for (;;) {
        size_t i = atomic_fetch_add_explicit(&g_idx, 1, memory_order_relaxed);
        if (i >= g_nfiles) break;
        search_file(&ob, g_files[i], &rbuf, &rcap, &lbuf, &lcap);
    }
    ob_flush(&ob);
    return NULL;
}

static void usage(void) { fputs("usage: cgrep_std_mt [-r] [-i] PATTERN PATH...\n", stderr); exit(2); }

int main(int argc, char **argv) {
    char **paths = malloc((size_t)argc * sizeof(char*));
    int np = 0, no_more = 0;
    for (int i = 1; i < argc; i++) {
        char *a = argv[i];
        if (!no_more && a[0] == '-' && a[1]) {
            if (a[1] == '-' && !a[2]) { no_more = 1; continue; }
            for (char *q = a+1; *q; q++) { if (*q=='i') g_ci=1; else if (*q=='r') g_r=1; else usage(); }
        } else if (!g_pat) g_pat = a; else paths[np++] = a;
    }
    if (!g_pat || np == 0) usage();
    g_patlen = strlen(g_pat);
    g_lpat = malloc(g_patlen + 1);
    for (size_t k = 0; k <= g_patlen; k++) g_lpat[k] = (char)tolower((unsigned char)g_pat[k]);
    g_multi = g_r || np > 1;

    for (int i = 0; i < np; i++) {
        struct stat st;
        if (stat(paths[i], &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) { if (g_r) nftw(paths[i], collect_cb, 32, FTW_PHYS); }
        else if (S_ISREG(st.st_mode)) {
            if (g_nfiles == g_cap) { g_cap = g_cap ? g_cap*2 : 1024; g_files = realloc(g_files, g_cap*sizeof(char*)); }
            g_files[g_nfiles++] = strdup(paths[i]);
        }
    }

    long nt = sysconf(_SC_NPROCESSORS_ONLN);
    if (nt < 1) nt = 1; if (nt > 16) nt = 16;
    pthread_t *th = malloc((size_t)nt * sizeof(pthread_t));
    for (long t = 0; t < nt; t++) pthread_create(&th[t], NULL, worker, NULL);
    for (long t = 0; t < nt; t++) pthread_join(th[t], NULL);

    return atomic_load(&g_matched) ? 0 : 1;
}
