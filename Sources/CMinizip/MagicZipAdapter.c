/* Copyright (c) 2026 MagicZip contributors. MIT licensed. */
#include "include/CMinizip.h"
#include "vendor/mz.h"
#include "vendor/mz_strm.h"
#include "vendor/mz_zip.h"
#include <stdio.h>
#include <unistd.h>
#include <zlib.h>

typedef struct {
    mz_stream stream;
    FILE *file;
} magiczip_file_stream;

struct magiczip_archive {
    magiczip_file_stream file;
    void *zip;
    int writing;
    int entry_open;
    int64_t read_size;
    uint32_t read_crc;
};

static int32_t file_is_open(void *s) {
    return ((magiczip_file_stream *)s)->file ? MZ_OK : MZ_OPEN_ERROR;
}
static int32_t file_read(void *s, void *buffer, int32_t count) {
    FILE *file = ((magiczip_file_stream *)s)->file;
    size_t result = fread(buffer, 1, (size_t)count, file);
    return ferror(file) ? MZ_READ_ERROR : (int32_t)result;
}
static int32_t file_write(void *s, const void *buffer, int32_t count) {
    FILE *file = ((magiczip_file_stream *)s)->file;
    size_t result = fwrite(buffer, 1, (size_t)count, file);
    return result == (size_t)count ? count : MZ_WRITE_ERROR;
}
static int64_t file_tell(void *s) {
    off_t result = ftello(((magiczip_file_stream *)s)->file);
    return result < 0 ? MZ_TELL_ERROR : result;
}
static int32_t file_seek(void *s, int64_t offset, int32_t origin) {
    return fseeko(((magiczip_file_stream *)s)->file, offset, origin) == 0 ? MZ_OK : MZ_SEEK_ERROR;
}
static int32_t file_error(void *s) {
    return ferror(((magiczip_file_stream *)s)->file) ? MZ_STREAM_ERROR : MZ_OK;
}
static int32_t file_get(void *s, int32_t prop, int64_t *value) {
    (void)s;
    if (prop == MZ_STREAM_PROP_DISK_SIZE) {
        *value = 0;
        return MZ_OK;
    }
    if (prop == MZ_STREAM_PROP_DISK_NUMBER) {
        *value = 0;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}
static int32_t file_set(void *s, int32_t prop, int64_t value) {
    (void)s;
    if (prop == MZ_STREAM_PROP_DISK_NUMBER && (value == 0 || value == -1 || value == UINT32_MAX)) {
        return MZ_OK;
    }
    return MZ_SUPPORT_ERROR;
}
static mz_stream_vtbl file_vtable = {NULL, file_is_open, file_read, file_write, file_tell, file_seek,
                                     NULL, file_error,   NULL,      NULL,       file_get,  file_set};

int32_t magiczip_open(int fd, int writing, magiczip_archive **result) {
    *result = NULL;
    magiczip_archive *archive = calloc(1, sizeof(*archive));
    if (!archive) {
        close(fd);
        return MZ_MEM_ERROR;
    }
    archive->writing = writing;
    archive->file.stream.vtbl = &file_vtable;
    archive->file.file = fdopen(fd, writing ? "w+b" : "rb");
    if (!archive->file.file) {
        close(fd);
        free(archive);
        return MZ_OPEN_ERROR;
    }
    archive->zip = mz_zip_create();
    if (!archive->zip) {
        fclose(archive->file.file);
        free(archive);
        return MZ_MEM_ERROR;
    }
    int32_t err = mz_zip_open(archive->zip, &archive->file, writing ? MZ_OPEN_MODE_WRITE : MZ_OPEN_MODE_READ);
    if (err == MZ_OK && !writing) {
        uint32_t disk = 0;
        err = mz_zip_get_disk_number_with_cd(archive->zip, &disk);
        if (err == MZ_OK && disk != 0) {
            err = MZ_SUPPORT_ERROR;
        }
    }
    if (err != MZ_OK) {
        mz_zip_close(archive->zip);
        mz_zip_delete(&archive->zip);
        fclose(archive->file.file);
        free(archive);
        return err;
    }
    *result = archive;
    return MZ_OK;
}

int32_t magiczip_close(magiczip_archive **pointer) {
    magiczip_archive *archive = *pointer;
    if (!archive) {
        return MZ_OK;
    }
    *pointer = NULL;
    int32_t err = MZ_OK;
    if (archive->entry_open) {
        err = archive->writing ? magiczip_write_close(archive) : magiczip_read_close(archive, 0);
    }
    int32_t end = mz_zip_close(archive->zip);
    if (err == MZ_OK) {
        err = end;
    }
    mz_zip_delete(&archive->zip);
    if (archive->writing) {
        if (fflush(archive->file.file) != 0 && err == MZ_OK) {
            err = MZ_WRITE_ERROR;
        }
        if (fsync(fileno(archive->file.file)) != 0 && err == MZ_OK) {
            err = MZ_CLOSE_ERROR;
        }
    }
    if (fclose(archive->file.file) != 0 && err == MZ_OK) {
        err = MZ_CLOSE_ERROR;
    }
    free(archive);
    return err;
}
int32_t magiczip_first(magiczip_archive *a) {
    return mz_zip_goto_first_entry(a->zip);
}
int32_t magiczip_next(magiczip_archive *a) {
    return mz_zip_goto_next_entry(a->zip);
}
int32_t magiczip_seek(magiczip_archive *a, int64_t position) {
    return mz_zip_goto_entry(a->zip, position);
}
int32_t magiczip_count(magiczip_archive *a, uint64_t *count) {
    return mz_zip_get_number_entry(a->zip, count);
}
int32_t magiczip_metadata(magiczip_archive *a, magiczip_info *out) {
    mz_zip_file *info = NULL;
    int32_t err = mz_zip_entry_get_info(a->zip, &info);
    if (err != MZ_OK) {
        return err;
    }
    memset(out, 0, sizeof(*out));
    out->name = info->filename;
    out->name_length = info->filename_size;
    out->method = info->compression_method;
    out->flags = info->flag;
    out->aes_version = info->aes_version;
    out->aes_strength = info->aes_strength;
    out->directory = mz_zip_entry_is_dir(a->zip) == MZ_OK;
    out->symlink = mz_zip_entry_is_symlink(a->zip) == MZ_OK;
    out->attributes = info->external_fa;
    out->made_by = info->version_madeby;
    out->compressed_size = info->compressed_size;
    out->uncompressed_size = info->uncompressed_size;
    out->modified = info->modified_date;
    out->position = mz_zip_get_entry(a->zip);
    out->crc = info->crc;
    out->disk = info->disk_number;
    return out->position < 0 ? MZ_FORMAT_ERROR : MZ_OK;
}
int32_t magiczip_read_open(magiczip_archive *a, const char *password) {
    int32_t err = mz_zip_entry_read_open(a->zip, 0, password);
    if (err == MZ_OK) {
        a->entry_open = 1;
        a->read_crc = 0;
        a->read_size = 0;
    }
    return err;
}
int32_t magiczip_read(magiczip_archive *a, void *buffer, int32_t count) {
    int32_t result = mz_zip_entry_read(a->zip, buffer, count);
    if (result > 0) {
        if (a->read_size > INT64_MAX - result) {
            return MZ_FORMAT_ERROR;
        }
        a->read_size += result;
        a->read_crc = (uint32_t)crc32(a->read_crc, buffer, (uInt)result);
    }
    return result;
}
int32_t magiczip_read_close(magiczip_archive *a, int verify) {
    int32_t err = MZ_OK;
    mz_zip_file *info = NULL;
    void *compress = NULL;
    if (verify) {
        err = mz_zip_entry_get_info(a->zip, &info);
        if (err == MZ_OK) {
            err = mz_zip_entry_get_compress_stream(a->zip, &compress);
        }
        int64_t consumed = 0;
        if (err == MZ_OK) {
            err = mz_stream_get_prop_int64(compress, MZ_STREAM_PROP_TOTAL_IN, &consumed);
        }
        if (err == MZ_OK) {
            int64_t overhead = info->aes_version ? 28 : 0; /* AES-256 salt + verifier + HMAC */
            if (info->compressed_size < overhead || consumed != info->compressed_size - overhead ||
                a->read_size != info->uncompressed_size) {
                err = MZ_DATA_ERROR;
            }
            if (err == MZ_OK && info->aes_version <= 1 && a->read_crc != info->crc) {
                err = MZ_CRC_ERROR;
            }
            /* Upstream read_close deletes the AES stream without authenticating it. */
            if (err == MZ_OK && info->aes_version) {
                err = mz_stream_close(((mz_stream *)compress)->base);
            }
        }
    }
    int32_t end = mz_zip_entry_read_close(a->zip, NULL, NULL, NULL);
    a->entry_open = 0;
    return err == MZ_OK ? end : err;
}
int32_t magiczip_write_open(magiczip_archive *a, const char *path, int directory, int16_t method,
                            int16_t level, int64_t modified, const char *password) {
    mz_zip_file info = {0};
    info.filename = path;
    info.flag = MZ_ZIP_FLAG_UTF8;
    info.compression_method = method;
    info.modified_date = modified;
    info.version_madeby = (MZ_HOST_SYSTEM_UNIX << 8) | 63;
    info.external_fa = (directory ? 0040700U : 0100600U) << 16;
    if (directory) {
        info.external_fa |= 0x10;
    }
    info.zip64 = MZ_ZIP64_FORCE; /* Streaming sources do not announce their final size. */
    if (password && !directory) {
        info.aes_version = 2;
        info.aes_strength = MZ_AES_STRENGTH_256;
    }
    int32_t err = mz_zip_entry_write_open(a->zip, &info, level, 0, password);
    if (err == MZ_OK) {
        a->entry_open = 1;
    }
    return err;
}
int32_t magiczip_write(magiczip_archive *a, const void *buffer, int32_t count) {
    return mz_zip_entry_write(a->zip, buffer, count);
}
int32_t magiczip_write_close(magiczip_archive *a) {
    int32_t err = mz_zip_entry_write_close(a->zip, 0, -1, -1);
    a->entry_open = 0;
    return err;
}
