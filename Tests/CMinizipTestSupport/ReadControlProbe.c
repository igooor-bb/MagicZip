#include "include/SecurityProbe.h"
#include "../../Sources/CMinizip/include/CMinizip.h"
#include "../../Sources/CMinizip/vendor/mz.h"
#include <fcntl.h>
#include <stdbool.h>

enum {
    READ_BUFFER_SIZE = 64,
    CATALOG_CHUNK_SIZE = 4096,
    CATALOG_LIMIT = 64 * 1024 * 1024,
};

typedef struct {
    int stop_after_refills;
    int refill_count;
} read_control;

static int32_t check_read(void *context) {
    read_control *control = context;
    control->refill_count++;
    if (control->stop_after_refills > 0 && control->refill_count >= control->stop_after_refills) {
        return MZ_READ_ERROR;
    }
    return MZ_OK;
}

int32_t magiczip_test_controlled_read(const char *path, int stop_after, int *read_calls) {
    magiczip_archive *archive = NULL;
    read_control control = {.stop_after_refills = stop_after};
    int32_t status = magiczip_open(open(path, O_RDONLY | O_CLOEXEC), 0, &archive);
    if (status == MZ_OK) {
        status = magiczip_first(archive);
    }
    if (status == MZ_OK) {
        status = magiczip_read_open(archive, NULL);
    }
    if (status == MZ_OK) {
        /* A single codec read may refill its input repeatedly without producing output. */
        uint8_t buffer[READ_BUFFER_SIZE];
        status = magiczip_read_controlled(archive, buffer, sizeof(buffer), check_read, &control);
    }
    *read_calls = control.refill_count;
    /* Preserve the read result: closing here only releases the probe's resources. */
    magiczip_close(&archive);
    return status;
}

int32_t magiczip_test_catalog_capacity(const char *path, int32_t length) {
    magiczip_archive *archive = NULL;
    bool passed = false;
    if (magiczip_open(open(path, O_RDONLY | O_CLOEXEC), 0, &archive) != MZ_OK) {
        goto cleanup;
    }

    /* Reject an oversized request without consuming the opportunity to prepare a valid catalog. */
    if (magiczip_catalog_prepare(archive, CATALOG_LIMIT + 1) != MZ_PARAM_ERROR) {
        goto cleanup;
    }
    if (magiczip_catalog_prepare(archive, length) != MZ_OK) {
        goto cleanup;
    }

    /* The Swift cases supply zero or a multiple of CATALOG_CHUNK_SIZE. Fill that exact capacity. */
    uint8_t buffer[CATALOG_CHUNK_SIZE] = {0};
    for (int32_t offset = 0; offset < length; offset += sizeof(buffer)) {
        if (magiczip_catalog_append(archive, buffer, sizeof(buffer)) != MZ_OK) {
            goto cleanup;
        }
    }
    passed = magiczip_catalog_append(archive, buffer, 1) == MZ_BUF_ERROR;

cleanup:
    magiczip_close(&archive);
    return passed;
}
