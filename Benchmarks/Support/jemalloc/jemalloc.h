/* conda-forge exports je_* symbols on macOS. Benchmark's system-library wrapper
 * expects the unprefixed statistics API exposed by the Homebrew build. */
#pragma once
#include_next <jemalloc/jemalloc.h>

static inline int mallctl(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    return je_mallctl(name, oldp, oldlenp, newp, newlen);
}

static inline int mallctlnametomib(const char *name, size_t *mibp, size_t *miblenp) {
    return je_mallctlnametomib(name, mibp, miblenp);
}

static inline int mallctlbymib(const size_t *mib, size_t miblen, void *oldp, size_t *oldlenp, void *newp,
                               size_t newlen) {
    return je_mallctlbymib(mib, miblen, oldp, oldlenp, newp, newlen);
}

static inline void malloc_stats_print(void (*write_cb)(void *, const char *), void *opaque,
                                      const char *opts) {
    je_malloc_stats_print(write_cb, opaque, opts);
}
