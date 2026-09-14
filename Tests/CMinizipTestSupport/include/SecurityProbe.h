#ifndef MAGICZIP_SECURITY_PROBE_H
#define MAGICZIP_SECURITY_PROBE_H

#include <stdint.h>

/** Returns 1 on success and 0 on a failed expectation. */
int32_t magiczip_test_crypto_failure(int stage, int reading);

/** Returns 1 on success and 0 on a failed expectation. */
int32_t magiczip_test_memory_growth(void);

/** Returns 1 on success and 0 on a failed expectation. */
int32_t magiczip_test_catalog_capacity(const char *path, int32_t length);

/** Returns the native read status and records input refills. stop_after == 0 disables interruption. */
int32_t magiczip_test_controlled_read(const char *path, int stop_after, int *read_calls);

#endif
