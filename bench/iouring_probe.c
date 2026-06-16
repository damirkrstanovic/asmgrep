// Microbenchmark: read every regular file under a directory two ways and time
// them, to see whether io_uring batching beats plain open/read/close for the
// asmgrep workload (thousands of small, page-cache-resident files).
//
//   build: gcc -O2 iouring_probe.c -luring -o iouring_probe
//   run:   ./iouring_probe <dir> [iters]
//
// Both methods read up to BUFSZ bytes per file (same work); we only sum bytes,
// since the point is the open/read/close transition cost, not searching.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <time.h>
#include <liburing.h>

#define BUFSZ   65536
#define QD      256          // batch / ring depth

static char **files;
static int nfiles, cap;

static void collect(const char *path) {
    DIR *d = opendir(path);
    if (!d) return;
    struct dirent *e;
    char child[4096];
    while ((e = readdir(d))) {
        if (e->d_name[0]=='.' && (e->d_name[1]==0 || (e->d_name[1]=='.'&&e->d_name[2]==0))) continue;
        snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        if (e->d_type == DT_DIR) collect(child);
        else if (e->d_type == DT_REG) {
            if (nfiles==cap) { cap = cap?cap*2:1024; files = realloc(files, cap*sizeof*files); }
            files[nfiles++] = strdup(child);
        } else if (e->d_type == DT_UNKNOWN) {
            struct stat st;
            if (stat(child,&st)==0) {
                if (S_ISDIR(st.st_mode)) collect(child);
                else if (S_ISREG(st.st_mode)) {
                    if (nfiles==cap) { cap = cap?cap*2:1024; files = realloc(files, cap*sizeof*files); }
                    files[nfiles++] = strdup(child);
                }
            }
        }
    }
    closedir(d);
}

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }

// --- sync: open/read/close per file ---
static long sync_pass(char *buf) {
    long total=0;
    for (int i=0;i<nfiles;i++) {
        int fd = open(files[i], O_RDONLY);
        if (fd<0) continue;
        ssize_t n = read(fd, buf, BUFSZ);
        if (n>0) total += n;
        close(fd);
    }
    return total;
}

// --- io_uring: linked openat_direct -> read(fixed) -> close_direct, batched ---
#define PER 200              // files per batch
static int fds[PER];
static long uring_pass(struct io_uring *ring, char *bufs) {
    long total=0;
    int i=0;
    while (i<nfiles) {
        int end = i+PER < nfiles ? i+PER : nfiles;
        int n = end - i;
        struct io_uring_sqe *s; struct io_uring_cqe *c; unsigned head; int seen;
        // phase 1: batch openat -> fds[k]
        for (int k=0;k<n;k++){ s=io_uring_get_sqe(ring); io_uring_prep_openat(s,AT_FDCWD,files[i+k],O_RDONLY,0); io_uring_sqe_set_data64(s,k); }
        io_uring_submit_and_wait(ring, n);
        for (int k=0;k<n;k++) fds[k]=-1;
        seen=0; io_uring_for_each_cqe(ring,head,c){ fds[io_uring_cqe_get_data64(c)]=c->res; seen++; }
        io_uring_cq_advance(ring,seen);
        // phase 2: batch read into per-slot buffers
        int rq=0;
        for (int k=0;k<n;k++){ if(fds[k]<0) continue; s=io_uring_get_sqe(ring); io_uring_prep_read(s,fds[k],bufs+(long)k*BUFSZ,BUFSZ,0); io_uring_sqe_set_data64(s,k); rq++; }
        if(rq){ io_uring_submit_and_wait(ring,rq); seen=0; io_uring_for_each_cqe(ring,head,c){ if(c->res>0) total+=c->res; seen++; } io_uring_cq_advance(ring,seen); }
        // phase 3: batch close
        int cq=0;
        for (int k=0;k<n;k++){ if(fds[k]<0) continue; s=io_uring_get_sqe(ring); io_uring_prep_close(s,fds[k]); io_uring_sqe_set_data64(s,k); cq++; }
        if(cq){ io_uring_submit_and_wait(ring,cq); seen=0; io_uring_for_each_cqe(ring,head,c){ seen++; } io_uring_cq_advance(ring,seen); }
        i = end;
    }
    return total;
}

int main(int argc, char **argv) {
    if (argc<2){fprintf(stderr,"usage: %s dir [iters]\n",argv[0]);return 2;}
    int iters = argc>2?atoi(argv[2]):20;
    collect(argv[1]);
    char *buf = malloc(BUFSZ);
    char *bufs = malloc((long)PER*BUFSZ);
    struct io_uring ring;
    if (io_uring_queue_init(QD, &ring, 0)){perror("queue_init");return 1;}

    long s=0,u=0; double ts=0,tu=0;
    for (int k=0;k<3;k++){ sync_pass(buf); uring_pass(&ring,bufs); }   // warm
    for (int k=0;k<iters;k++){ double a=now(); s=sync_pass(buf); ts+=now()-a; }
    for (int k=0;k<iters;k++){ double a=now(); u=uring_pass(&ring,bufs); tu+=now()-a; }

    printf("files=%d  bytes(sync)=%ld bytes(uring)=%ld\n", nfiles, s, u);
    printf("sync  : %.3f ms/pass\n", ts/iters*1000);
    printf("uring : %.3f ms/pass\n", tu/iters*1000);
    printf("io_uring speedup: %.2fx\n", ts/tu);
    return 0;
}
