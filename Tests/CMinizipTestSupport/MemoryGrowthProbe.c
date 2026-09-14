/* Exercise the real memory stream with counted allocations and a controlled allocation failure. */
#include "include/SecurityProbe.h"
#include "../../Sources/CMinizip/vendor/mz.h"
#include "../../Sources/CMinizip/vendor/mz_strm.h"
#include <stdbool.h>

enum {
    CHUNK_SIZE = 4096,
    CHUNK_COUNT = 2048,
    PAYLOAD_SIZE = CHUNK_SIZE * CHUNK_COUNT,
    MAX_ALLOCATION_COUNT = 13,
    MAX_REQUESTED_BYTES = 2 * PAYLOAD_SIZE,
};

typedef struct {
    int count;
    size_t requested_bytes;
    bool fail;
} allocation_probe;

static _Thread_local allocation_probe allocation;

/* Defined before substitution so successful requests reach the system allocator. */
static void *counted_malloc(size_t size) {
    allocation.count++;
    allocation.requested_bytes += size;
    return allocation.fail ? NULL : malloc(size);
}

static void *counted_realloc(void *pointer, size_t size) {
    allocation.count++;
    allocation.requested_bytes += size;
    return allocation.fail ? NULL : realloc(pointer, size);
}

/* Isolate the included memory-stream implementation from the SDK's symbols. */
#undef mz_stream_mem_open
#define mz_stream_mem_open magiczip_test_mz_stream_mem_open
#undef mz_stream_mem_is_open
#define mz_stream_mem_is_open magiczip_test_mz_stream_mem_is_open
#undef mz_stream_mem_read
#define mz_stream_mem_read magiczip_test_mz_stream_mem_read
#undef mz_stream_mem_write
#define mz_stream_mem_write magiczip_test_mz_stream_mem_write
#undef mz_stream_mem_tell
#define mz_stream_mem_tell magiczip_test_mz_stream_mem_tell
#undef mz_stream_mem_seek
#define mz_stream_mem_seek magiczip_test_mz_stream_mem_seek
#undef mz_stream_mem_close
#define mz_stream_mem_close magiczip_test_mz_stream_mem_close
#undef mz_stream_mem_error
#define mz_stream_mem_error magiczip_test_mz_stream_mem_error
#undef mz_stream_mem_set_buffer
#define mz_stream_mem_set_buffer magiczip_test_mz_stream_mem_set_buffer
#undef mz_stream_mem_get_buffer
#define mz_stream_mem_get_buffer magiczip_test_mz_stream_mem_get_buffer
#undef mz_stream_mem_get_buffer_at
#define mz_stream_mem_get_buffer_at magiczip_test_mz_stream_mem_get_buffer_at
#undef mz_stream_mem_get_buffer_at_current
#define mz_stream_mem_get_buffer_at_current magiczip_test_mz_stream_mem_get_buffer_at_current
#undef mz_stream_mem_get_buffer_length
#define mz_stream_mem_get_buffer_length magiczip_test_mz_stream_mem_get_buffer_length
#undef mz_stream_mem_set_buffer_limit
#define mz_stream_mem_set_buffer_limit magiczip_test_mz_stream_mem_set_buffer_limit
#undef mz_stream_mem_set_initial_capacity
#define mz_stream_mem_set_initial_capacity magiczip_test_mz_stream_mem_set_initial_capacity
#undef mz_stream_mem_create
#define mz_stream_mem_create magiczip_test_mz_stream_mem_create
#undef mz_stream_mem_delete
#define mz_stream_mem_delete magiczip_test_mz_stream_mem_delete
#undef mz_stream_mem_get_interface
#define mz_stream_mem_get_interface magiczip_test_mz_stream_mem_get_interface

#define realloc counted_realloc
#define malloc counted_malloc
#include "../../Sources/CMinizip/vendor/mz_strm_mem.c"
#undef realloc
#undef malloc

static bool write_pattern(void *memory) {
    uint8_t buffer[CHUNK_SIZE];
    for (int chunk = 0; chunk < CHUNK_COUNT; chunk++) {
        memset(buffer, chunk & 255, sizeof(buffer));
        if (mz_stream_write(memory, buffer, sizeof(buffer)) != sizeof(buffer)) {
            return false;
        }
    }
    return true;
}

static bool verify_pattern(void *memory) {
    uint8_t buffer[CHUNK_SIZE];
    mz_stream_seek(memory, 0, MZ_SEEK_SET);
    for (int chunk = 0; chunk < CHUNK_COUNT; chunk++) {
        if (mz_stream_read(memory, buffer, sizeof(buffer)) != sizeof(buffer)) {
            return false;
        }
        for (size_t index = 0; index < sizeof(buffer); index++) {
            if (buffer[index] != (chunk & 255)) {
                return false;
            }
        }
    }
    return true;
}

int32_t magiczip_test_memory_growth(void) {
    bool passed = false;
    allocation = (allocation_probe){0};
    void *memory = mz_stream_mem_create();

    /* Small appends must reach 8 MiB with a bounded number and total size of allocations. */
    if (mz_stream_open(memory, NULL, MZ_OPEN_MODE_CREATE) != MZ_OK || !write_pattern(memory)) {
        goto cleanup;
    }
    if (allocation.count > MAX_ALLOCATION_COUNT || allocation.requested_bytes > MAX_REQUESTED_BYTES) {
        goto cleanup;
    }

    /* Force the next growth to fail, then verify the original length and every byte. */
    uint8_t byte = 255;
    allocation.fail = true;
    int32_t growth_status = mz_stream_write(memory, &byte, 1);
    allocation.fail = false;
    if (growth_status != MZ_BUF_ERROR) {
        goto cleanup;
    }
    int32_t length = 0;
    mz_stream_mem_get_buffer_length(memory, &length);
    if (length != PAYLOAD_SIZE || !verify_pattern(memory)) {
        goto cleanup;
    }

    /* Invalid sizes must be rejected before the one-byte source buffer can be read. */
    passed = mz_stream_write(memory, &byte, -1) == MZ_PARAM_ERROR;
    passed = passed && mz_stream_write(memory, &byte, INT32_MAX) == MZ_PARAM_ERROR;

cleanup:
    allocation.fail = false;
    mz_stream_delete(&memory);
    return passed;
}
