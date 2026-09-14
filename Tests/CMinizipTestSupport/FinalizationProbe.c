/* Test-only stream: inject a write failure exactly at entry/archive finalization. */
#include "include/FinalizationProbe.h"
#include "../../Sources/CMinizip/vendor/mz.h"
#include "../../Sources/CMinizip/vendor/mz_strm.h"
#include "../../Sources/CMinizip/vendor/mz_zip.h"

typedef struct {
    mz_stream stream;
    int64_t position;
    int fail;
} fault_stream;

static int32_t opened(void *s) {
    (void)s;
    return MZ_OK;
}

static int32_t write_bytes(void *s, const void *b, int32_t n) {
    (void)b;
    fault_stream *stream = s;
    if (stream->fail) {
        return MZ_WRITE_ERROR;
    }
    stream->position += n;
    return n;
}

static int64_t tell(void *s) {
    return ((fault_stream *)s)->position;
}

static int32_t seek(void *s, int64_t offset, int32_t origin) {
    fault_stream *stream = s;
    if (origin == MZ_SEEK_SET) {
        stream->position = offset;
    } else {
        stream->position += offset;
    }
    return MZ_OK;
}

static mz_stream_vtbl vtable = {NULL, opened, NULL, write_bytes, tell, seek,
                                NULL, NULL,   NULL, NULL,        NULL, NULL};

int32_t magiczip_test_finalization_failure(int archive_close) {
    fault_stream stream = {{&vtable, NULL}, 0, 0};
    void *zip = mz_zip_create();
    int32_t err = mz_zip_open(zip, &stream, MZ_OPEN_MODE_WRITE);
    mz_zip_file info = {0};
    info.filename = "entry";
    info.compression_method = MZ_COMPRESS_METHOD_DEFLATE;
    info.zip64 = MZ_ZIP64_FORCE;
    if (err == MZ_OK) {
        err = mz_zip_entry_write_open(zip, &info, 6, 0, NULL);
    }
    if (err == MZ_OK && mz_zip_entry_write(zip, "payload", 7) != 7) {
        err = MZ_WRITE_ERROR;
    }
    if (err == MZ_OK) {
        stream.fail = !archive_close;
        err = mz_zip_entry_write_close(zip, 0, -1, -1);
    }
    if (archive_close) {
        stream.fail = 1;
    }
    int32_t end = mz_zip_close(zip);
    mz_zip_delete(&zip);
    return err == MZ_OK ? end : err;
}
