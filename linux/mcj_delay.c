// LD_PRELOAD shim that widens the MulticoreJIT torn-write window so a concurrent reader
// reliably observes the non-atomic in-place rewrite on an UNPATCHED runtime -- while
// leaving a fixed runtime untouched (the fix writes to a "*.tmp" path and only touches
// the final path via an atomic rename, which has no intermediate state to delay).
//
// It interposes the STDIO entry points (fopen/fopen64, fwrite, fclose): the runtime
// writes the profile through CRT fopen/fwrite (src/coreclr/minipal/Unix/dn-stdio.cpp),
// and glibc stdio reaches its internal open/write through libc-internal aliases that
// bypass PLT interposition -- hooking the raw open/write wrappers never fires for these
// writes, hooking the stdio functions themselves does. fwrite delays widen the gaps
// between the stdio buffer's flushes to disk, which is where the torn states live.
//
// Keys on the FINAL profile path only (basename contains MCJ_TARGET and does NOT end
// in ".tmp"), and only for write-mode opens:
//   - after fopen("w...") of the final path -> sleep (widen the truncated, size-0 window)
//   - after each fwrite() to that stream    -> sleep (widen the partial-body windows)
//
// If MCJ_DELAY_REPORT names a file, each process appends its hook hit counts to it at
// exit, so the driver can prove the shim fired (control: hits > 0) or was evaded by
// construction (fix: 0 hits, every write goes to a "*.tmp" path).
// build: gcc -O2 -shared -fPIC mcj_delay.c -o mcj_delay.so -ldl
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

static FILE*  (*real_fopen)(const char*, const char*);
static FILE*  (*real_fopen64)(const char*, const char*);
static size_t (*real_fwrite)(const void*, size_t, size_t, FILE*);
static int    (*real_fclose)(FILE*);

#define MAXTRACK 64
static FILE* tracked[MAXTRACK];
static pthread_mutex_t tracked_lock = PTHREAD_MUTEX_INITIALIZER;

static const char* target = "StartupProfileData-Repro";
static int delay_open_us  = 5000;   // size-0 window after the truncating open
static int delay_write_us = 2000;   // partial window between buffer flushes
static unsigned long hits_open = 0, hits_write = 0;

static void report(void){
    const char* path = getenv("MCJ_DELAY_REPORT");
    if (!path || !*path || !real_fopen || !real_fclose) return;
    FILE* f = real_fopen(path, "a");
    if (!f) return;
    fprintf(f, "open=%lu write=%lu\n", hits_open, hits_write);
    real_fclose(f);
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void init_once(void){
    real_fopen   = (FILE* (*)(const char*, const char*))dlsym(RTLD_NEXT, "fopen");
    real_fopen64 = (FILE* (*)(const char*, const char*))dlsym(RTLD_NEXT, "fopen64");
    real_fwrite  = (size_t (*)(const void*, size_t, size_t, FILE*))dlsym(RTLD_NEXT, "fwrite");
    real_fclose  = (int (*)(FILE*))dlsym(RTLD_NEXT, "fclose");
    const char* t = getenv("MCJ_TARGET"); if (t && *t) target = t;
    const char* d;
    if ((d = getenv("MCJ_DELAY_OPEN_US")))  delay_open_us  = atoi(d);
    if ((d = getenv("MCJ_DELAY_WRITE_US"))) delay_write_us = atoi(d);
    if (getenv("MCJ_DELAY_REPORT")) atexit(report);
}
static void init(void){ pthread_once(&once, init_once); }

// usleep may clobber errno; the interposed function's caller must see the real call's errno.
static void sleep_keep_errno(int us){ int e = errno; usleep(us); errno = e; }

// final profile path = basename contains target AND does not end in ".tmp"
static int is_final_target(const char* path){
    if (!path) return 0;
    const char* b = strrchr(path, '/'); b = b ? b + 1 : path;
    if (!strstr(b, target)) return 0;
    size_t bl = strlen(b);
    if (bl >= 4 && strcmp(b + bl - 4, ".tmp") == 0) return 0;
    return 1;
}

static void track(FILE* f){
    pthread_mutex_lock(&tracked_lock);
    for (int i = 0; i < MAXTRACK; i++) if (!tracked[i]) { tracked[i] = f; break; }
    pthread_mutex_unlock(&tracked_lock);
}
static int is_tracked(FILE* f){
    int r = 0;
    pthread_mutex_lock(&tracked_lock);
    for (int i = 0; i < MAXTRACK; i++) if (tracked[i] == f) { r = 1; break; }
    pthread_mutex_unlock(&tracked_lock);
    return r;
}
static void untrack(FILE* f){
    pthread_mutex_lock(&tracked_lock);
    for (int i = 0; i < MAXTRACK; i++) if (tracked[i] == f) tracked[i] = NULL;
    pthread_mutex_unlock(&tracked_lock);
}

static FILE* after_fopen(FILE* f, const char* path, const char* mode){
    if (f && mode && mode[0] == 'w' && is_final_target(path)){
        track(f);
        __sync_fetch_and_add(&hits_open, 1);
        sleep_keep_errno(delay_open_us);
    }
    return f;
}

FILE* fopen(const char* path, const char* mode){
    init();
    return after_fopen(real_fopen(path, mode), path, mode);
}
FILE* fopen64(const char* path, const char* mode){
    init();
    return after_fopen(real_fopen64(path, mode), path, mode);
}
size_t fwrite(const void* ptr, size_t size, size_t nmemb, FILE* stream){
    init();
    size_t r = real_fwrite(ptr, size, nmemb, stream);
    if (is_tracked(stream)){
        __sync_fetch_and_add(&hits_write, 1);
        sleep_keep_errno(delay_write_us);
    }
    return r;
}
int fclose(FILE* stream){
    init();
    untrack(stream);
    return real_fclose(stream);
}
