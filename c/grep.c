// cgrep - the same program as asm/grep.s, in C, to test whether the assembly
// itself bought any speed (vs the algorithm + syscall strategy).
//
// Same logic: literal substring search, -r/-i, binary-file skip, read() small
// files into a reused per-thread buffer (mmap for large), rare-byte
// search-then-locate-line matching, and a parallel directory work-queue walker.
//
//   cc -O2 -pthread -march=native -o cgrep grep.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/sysinfo.h>
#include <immintrin.h>

#define BIN_PEEK   65536
#define READBUF_SZ 262144
#define OUTBUF_SZ  65536
#define MAX_THREADS 16

// byte-frequency rank: low = rare (good memchr pivot), high = common.
static const unsigned char freq[256] = {
 1,1,1,1,1,1,1,1,1,1,250,1,1,1,1,1,  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
 255,1,50,1,1,1,1,1,50,50,1,1,50,50,50,50, 60,60,60,60,60,60,60,60,60,60,50,1,1,50,1,1,
 1,66,33,45,50,80,38,36,58,63,20,23,48,41,61,65, 35,20,56,60,70,43,26,40,20,36,20,1,1,1,1,50,
 1,200,100,135,150,240,115,110,175,190,45,70,145,125,185,195, 105,38,170,180,210,130,80,120,40,108,35,1,1,1,1,1,
 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};

// ---- pattern (read-only after setup) ----
static const char *g_pat;          // original pattern
static char g_pat_lc[1<<16];       // lowercased pattern (for -i)
static const char *g_cmp;          // pattern to compare against (lc if -i)
static size_t g_patlen;
static int g_i, g_r, g_multi, g_fold;
// matching strategy mirrors asm/grep.s: pick the two rarest pattern bytes; scan
// for byte A (memchr), then cheaply require byte B at a fixed offset before the
// full verify (the "two-byte filter"). For a rare A, drop to single-byte.
static size_t g_off_a, g_off_b;
static unsigned char g_a0, g_a1;  // byte A, both cases for -i
static unsigned char g_b0, g_b1;  // byte B, both cases for -i
static int g_single;              // 1 = single-byte (A is rare enough)

static atomic_int g_match, g_err;

static inline unsigned char fold(unsigned char c){ return (c>='A'&&c<='Z') ? c+32 : c; }
static inline int verify(const char *s);
static inline const char *find_a(const char *p, const char *end);

static void prep_pattern(void){
    g_patlen = strlen(g_pat);
    g_fold = g_i;
    if (g_i){ for (size_t k=0;k<g_patlen;k++) g_pat_lc[k]=fold((unsigned char)g_pat[k]); g_cmp=g_pat_lc; }
    else g_cmp = g_pat;
    if (!g_patlen) return;
    // off_a = argmin rank
    size_t a=0; int br=256;
    for (size_t k=0;k<g_patlen;k++){ int r=freq[(unsigned char)g_cmp[k]]; if (r<br){br=r;a=k;} }
    g_off_a=a; g_off_b=a;
    if (g_patlen>=2){
        size_t b=0; int br2=256; int found=0;
        for (size_t k=0;k<g_patlen;k++){ if(k==a) continue; int r=freq[(unsigned char)g_cmp[k]]; if(!found||r<br2){br2=r;b=k;found=1;} }
        if (g_off_a>b){ size_t t=g_off_a; g_off_a=b; g_off_b=t; } else g_off_b=b;
    }
    g_a0=(unsigned char)g_cmp[g_off_a]; g_a1=g_a0;
    if (g_i && g_a0>='a'&&g_a0<='z') g_a1=g_a0-32;
    g_b0=(unsigned char)g_cmp[g_off_b]; g_b1=g_b0;
    if (g_i && g_b0>='a'&&g_b0<='z') g_b1=g_b0-32;
    g_single = (g_patlen<2) || (freq[g_a0] <= 64);
}

// first match start in [floor,end) via AVX2 two-byte filter (32 bytes/iter),
// the C analogue of the asm scan loop; or NULL.
__attribute__((target("avx2")))
static const char *fm_two(const char *floor, const char *end){
    const __m256i A0=_mm256_set1_epi8(g_a0), A1=_mm256_set1_epi8(g_a1);
    const __m256i B0=_mm256_set1_epi8(g_b0), B1=_mm256_set1_epi8(g_b1);
    size_t dd=g_off_b-g_off_a;
    const char *p=floor;
    while (p + 32 + dd <= end){
        __m256i v=_mm256_loadu_si256((const __m256i*)p);
        __m256i am=_mm256_or_si256(_mm256_cmpeq_epi8(v,A0),_mm256_cmpeq_epi8(v,A1));
        __m256i w=_mm256_loadu_si256((const __m256i*)(p+dd));
        __m256i bm=_mm256_or_si256(_mm256_cmpeq_epi8(w,B0),_mm256_cmpeq_epi8(w,B1));
        unsigned mask=_mm256_movemask_epi8(_mm256_and_si256(am,bm));
        while (mask){
            int k=__builtin_ctz(mask);
            const char *start=p+k-g_off_a;
            if (start>=floor && start+g_patlen<=end && verify(start)) return start;
            mask &= mask-1;
        }
        p += 32;
    }
    for (; p<end; p++){                        // scalar tail
        if ((unsigned char)*p!=g_a0 && (unsigned char)*p!=g_a1) continue;
        const char *start=p-g_off_a;
        if (start<floor || start+g_patlen>end) continue;
        unsigned char hb=(unsigned char)start[g_off_b]; if(g_fold)hb=fold(hb);
        if (hb!=(unsigned char)g_cmp[g_off_b]) continue;
        if (verify(start)) return start;
    }
    return NULL;
}

// single-byte fast path (rare A): memchr is glibc's vectorized scan, ideal here.
static const char *fm_single(const char *floor, const char *end){
    const char *p=floor;
    while (p<end){
        const char *hit=find_a(p,end);
        if (!hit) return NULL;
        const char *start=hit-g_off_a;
        if (start<floor){ p=hit+1; continue; }
        if (start+g_patlen>end) return NULL;
        if (verify(start)) return start;
        p=hit+1;
    }
    return NULL;
}

static inline int verify(const char *s){
    if (!g_fold) return memcmp(s, g_cmp, g_patlen)==0;
    for (size_t k=0;k<g_patlen;k++) if (fold((unsigned char)s[k]) != (unsigned char)g_cmp[k]) return 0;
    return 1;
}

// find next occurrence of byte A at/after p (either case when -i)
static inline const char *find_a(const char *p, const char *end){
    if (!g_i) return memchr(p, g_a0, end-p);
    const char *x = memchr(p, g_a0, end-p);
    const char *y = memchr(p, g_a1, end-p);
    if (!x) return y; if (!y) return x; return x<y?x:y;
}

// ---- per-thread context ----
typedef struct { char *rbuf; char *obuf; size_t olen; } Ctx;
static pthread_mutex_t g_outlock = PTHREAD_MUTEX_INITIALIZER;

static void flush_ctx(Ctx *c){
    if (!c->olen) return;
    pthread_mutex_lock(&g_outlock);
    ssize_t w = write(1, c->obuf, c->olen); (void)w;
    pthread_mutex_unlock(&g_outlock);
    c->olen=0;
}
// emit one whole line atomically (prefix + body + \n), never split by a flush
static void emit(Ctx *c, const char *path, size_t plen, const char *line, size_t llen){
    atomic_store_explicit(&g_match,1,memory_order_relaxed);
    size_t need = llen+1 + (g_multi ? plen+1 : 0);
    if (need > OUTBUF_SZ){               // giant line: stream under lock
        pthread_mutex_lock(&g_outlock);
        if (g_multi){ ssize_t w; w=write(1,path,plen);(void)w; w=write(1,":",1);(void)w; }
        ssize_t w; w=write(1,line,llen);(void)w; w=write(1,"\n",1);(void)w;
        pthread_mutex_unlock(&g_outlock);
        return;
    }
    if (c->olen + need > OUTBUF_SZ) flush_ctx(c);
    char *o = c->obuf + c->olen;
    if (g_multi){ memcpy(o,path,plen); o+=plen; *o++=':'; }
    memcpy(o,line,llen); o+=llen; *o++='\n';
    c->olen = o - c->obuf;
}

static void scan(Ctx *c, const char *base, size_t size, const char *path, size_t plen){
    const char *end = base+size;
    size_t peek = size<BIN_PEEK?size:BIN_PEEK;
    if (memchr(base,0,peek)) return;                 // binary file: skip
    if (g_patlen==0){                                // empty pattern: every line
        const char *p=base;
        while (p<end){ const char *nl=memchr(p,'\n',end-p); const char *le=nl?nl:end;
            emit(c,path,plen,p,le-p); if(!nl)break; p=nl+1; }
        return;
    }
    const char *p=base;
    while (p<end){
        const char *start = g_single ? fm_single(p,end) : fm_two(p,end);
        if (!start) break;
        const char *ls = memrchr(base,'\n',start-base);
        ls = ls?ls+1:base;
        const char *nl = memchr(start,'\n',end-start);
        const char *le = nl?nl:end;
        emit(c,path,plen,ls,le-ls);
        p = le+1;
    }
}

static void search_file(Ctx *c, const char *path){
    int fd=open(path,O_RDONLY); if (fd<0){ atomic_store(&g_err,1); return; }
    ssize_t n=read(fd,c->rbuf,READBUF_SZ);
    if (n<0){ close(fd); atomic_store(&g_err,1); return; }
    if (n<READBUF_SZ){ if(n>0) scan(c,c->rbuf,n,path,strlen(path)); close(fd); return; }
    // large file: mmap
    struct stat st;
    if (fstat(fd,&st)==0 && st.st_size>0){
        void *m=mmap(0,st.st_size,PROT_READ,MAP_PRIVATE,fd,0);
        if (m!=MAP_FAILED){ scan(c,m,st.st_size,path,strlen(path)); munmap(m,st.st_size); }
    }
    close(fd);
}

// ---- directory work queue ----
static char **g_q; static size_t g_qtop,g_qcap; static pthread_mutex_t g_qlock=PTHREAD_MUTEX_INITIALIZER;
static atomic_long g_pending;

static void q_push(char *d){
    pthread_mutex_lock(&g_qlock);
    if (g_qtop==g_qcap){ g_qcap=g_qcap?g_qcap*2:1024; g_q=realloc(g_q,g_qcap*sizeof*g_q); }
    g_q[g_qtop++]=d; atomic_fetch_add(&g_pending,1);
    pthread_mutex_unlock(&g_qlock);
}
static char *q_pop(void){
    char *d=NULL;
    pthread_mutex_lock(&g_qlock);
    if (g_qtop>0) d=g_q[--g_qtop];
    pthread_mutex_unlock(&g_qlock);
    return d;
}

static void traverse(Ctx *c, const char *dir){
    DIR *d=opendir(dir); if(!d) return;
    struct dirent *e; char child[4096]; size_t dl=strlen(dir);
    while ((e=readdir(d))){
        const char *nm=e->d_name;
        if (nm[0]=='.' && (nm[1]==0 || (nm[1]=='.'&&nm[2]==0))) continue;
        if (e->d_type==DT_LNK) continue;
        int n=snprintf(child,sizeof child,"%s/%s",dir,nm); if(n<=0||(size_t)n>=sizeof child) continue;
        if (e->d_type==DT_DIR){ if (g_r) q_push(strdup(child)); }
        else if (e->d_type==DT_REG){ search_file(c,child); }
        else if (e->d_type==DT_UNKNOWN){
            struct stat st; if (stat(child,&st)==0){
                if (S_ISDIR(st.st_mode)){ if(g_r) q_push(strdup(child)); }
                else if (S_ISREG(st.st_mode)) search_file(c,child);
            }
        }
        (void)dl;
    }
    closedir(d);
}

static void *worker(void *arg){
    Ctx *c=arg;
    for (;;){
        char *d=q_pop();
        if (d){ traverse(c,d); free(d); atomic_fetch_sub(&g_pending,1); }
        else { if (atomic_load(&g_pending)==0) break; sched_yield(); }
    }
    flush_ctx(c);
    return NULL;
}

int main(int argc, char **argv){
    int no_more=0, pat_seen=0; int npaths=0;
    // pass 1: classify
    for (int i=1;i<argc;i++){
        char *a=argv[i];
        if (!no_more && a[0]=='-' && a[1]){
            if (a[1]=='-'&&a[2]==0){ no_more=1; continue; }
            for (char *q=a+1;*q;q++){ if(*q=='i')g_i=1; else if(*q=='r')g_r=1; else { fprintf(stderr,"usage: cgrep [-r] [-i] PATTERN PATH...\n"); return 2; } }
        } else { if(!g_pat) g_pat=a; else npaths++; }
    }
    if (!g_pat || npaths==0){ fprintf(stderr,"usage: cgrep [-r] [-i] PATTERN PATH...\n"); return 2; }
    g_multi = g_r || npaths>1;
    prep_pattern();

    int nt = get_nprocs(); if (nt<1) nt=1; if (nt>MAX_THREADS) nt=MAX_THREADS;
    Ctx ctxs[MAX_THREADS];
    for (int t=0;t<nt;t++){ ctxs[t].rbuf=malloc(READBUF_SZ); ctxs[t].obuf=malloc(OUTBUF_SZ); ctxs[t].olen=0; }

    // pass 2: roots
    no_more=0; pat_seen=0;
    for (int i=1;i<argc;i++){
        char *a=argv[i];
        if (!no_more && a[0]=='-' && a[1]){ if(a[1]=='-'&&a[2]==0)no_more=1; continue; }
        if (!pat_seen){ pat_seen=1; continue; }            // the pattern
        struct stat st;
        if (stat(a,&st)!=0){ atomic_store(&g_err,1); continue; }
        if (S_ISDIR(st.st_mode)){ if (g_r) q_push(strdup(a)); }
        else if (S_ISREG(st.st_mode)) search_file(&ctxs[0],a);
    }

    if (atomic_load(&g_pending)>0){
        pthread_t th[MAX_THREADS];
        for (int t=1;t<nt;t++) pthread_create(&th[t],0,worker,&ctxs[t]);
        worker(&ctxs[0]);                                  // main is worker 0
        for (int t=1;t<nt;t++) pthread_join(th[t],0);
    } else {
        flush_ctx(&ctxs[0]);                               // only root files
    }

    if (atomic_load(&g_err)) return 2;
    return atomic_load(&g_match) ? 0 : 1;
}
