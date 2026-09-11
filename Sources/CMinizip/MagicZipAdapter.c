/* Copyright (c) 2026 MagicZip contributors. MIT licensed. */
#include "include/CMinizip.h"
#include "vendor/mz.h"
#include "vendor/mz_strm.h"
#include "vendor/mz_strm_mem.h"
#include "vendor/mz_zip.h"
#include <stdio.h>
#include <unistd.h>

typedef struct {
    mz_stream stream;
    FILE *file;
} magiczip_file_stream;

struct magiczip_archive {
    magiczip_file_stream file;
    void *zip;
    void *catalog; /* Owned decrypted directory, installed only after authentication. */
    int secure;
    int writing;
    int entry_open;
    int64_t read_size;
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
    /* Single-file stream: disk 0 is real; minizip uses -1 for the central-directory disk,
     * including (uint32_t)-1 in mz_zip_entry_seek_local_header. Neither sentinel means multipart. */
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
    mz_stream_mem_delete(&archive->catalog);
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
            /* AES-256: 16-byte salt + 2-byte verifier + 10-byte HMAC are included in ZIP
             * compressed_size, but not in the codec input count. Swift admits only AES-256.
             * https://www.winzip.com/en/support/aes-encryption/ (Encrypted file storage format) */
            int64_t overhead = info->aes_version ? 28 : 0;
            if (info->compressed_size < overhead || consumed != info->compressed_size - overhead ||
                a->read_size != info->uncompressed_size) {
                err = MZ_DATA_ERROR;
            }
            /* Version 0 is plaintext here; AE-1 requires CRC, while AE-2 stores zero and uses HMAC. */
            if (err == MZ_OK && info->aes_version <= 1) {
                uint32_t computed_crc = 0;
                err = mz_zip_entry_get_computed_crc(a->zip, &computed_crc);
                if (err == MZ_OK && computed_crc != info->crc) {
                    err = MZ_CRC_ERROR;
                }
            }
            /* Upstream read_close deletes the AES stream without authenticating it. */
            if (err == MZ_OK && info->aes_version) {
                err = mz_stream_close(((mz_stream *)compress)->base);
                /* Store uses a raw pass-through codec whose is_open delegates to its base.
                 * Authentication has closed AES. Rebind the raw codec to the still-open file
                 * so checked codec closure does not mistake successful authentication for an
                 * I/O failure. No payload is read after this point (read_close gets NULL outputs). */
                if (err == MZ_OK && info->compression_method == MZ_COMPRESS_METHOD_STORE) {
                    mz_stream_set_base(compress, &a->file);
                }
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
    info.flag = MZ_ZIP_FLAG_UTF8 | (a->secure ? MZ_ZIP_FLAG_MASK_LOCAL_INFO : 0);
    info.compression_method = method;
    info.modified_date = modified;
    /* APPNOTE 4.4.2: high byte = host, low byte = major * 10 + minor (63 means ZIP 6.3).
     * This is the producer version, not the minimum extraction version.
     * https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT */
    info.version_madeby = (MZ_HOST_SYSTEM_UNIX << 8) | 63;
    /* minizip UNIX convention: upper word = POSIX type + mode (directory 040000 | 0700,
     * regular file 0100000 | 0600); low DOS attribute bit 0x10 also marks directories.
     * See vendor/mz_zip.c, mz_zip_attrib_is_dir and mz_zip_attrib_convert. */
    info.external_fa = (directory ? 0040700U : 0100600U) << 16;
    if (directory) {
        info.external_fa |= 0x10;
    }
    info.zip64 = MZ_ZIP64_FORCE; /* Streaming sources do not announce their final size. */
    if (password && !directory) {
        /* Write AE-2: authenticated payload without a plaintext CRC field. */
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
    if (!a->entry_open) {
        return MZ_OK;
    }
    /* Non-raw writes compute CRC internally; negative sizes request codec totals.
     * See mz_zip_entry_write_close in minizip-ng 4.2.2 (vendor/mz_zip.c). */
    int32_t err = mz_zip_entry_write_close(a->zip, 0, -1, -1);
    a->entry_open = 0;
    return err;
}

/* minizip-ng CDCD extension: a single encrypted entry holds the real directory.
 * Keep this in the checked adapter instead of importing the high-level rw layer,
 * whose whole-directory copy has no application budget or cancellation checkpoints. */
int32_t magiczip_catalog_info(magiczip_archive *a, uint64_t *entries) {
    int32_t err = magiczip_first(a);
    if (err == MZ_END_OF_LIST) {
        return MZ_EXIST_ERROR;
    }
    if (err != MZ_OK) {
        return err;
    }
    mz_zip_file *info = NULL;
    err = mz_zip_entry_get_info(a->zip, &info);
    if (err != MZ_OK) {
        return err;
    }
    const uint8_t *extra = (const uint8_t *)info->extrafield;
    int found = 0;
    /* APPNOTE 4.5.1: each extra field starts with little-endian uint16 ID + uint16 length.
     * CDCD adds one uint64 entry count (8 bytes), as defined by minizip-ng, not PKWARE.
     * https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz_zip_rw.c (mz_zip_writer_zip_cd) */
    for (uint32_t offset = 0; offset < info->extrafield_size;) {
        if (info->extrafield_size - offset < 4) {
            return MZ_FORMAT_ERROR;
        }
        uint16_t type = extra[offset] | ((uint16_t)extra[offset + 1] << 8);
        uint16_t size = extra[offset + 2] | ((uint16_t)extra[offset + 3] << 8);
        offset += 4;
        if (size > info->extrafield_size - offset) {
            return MZ_FORMAT_ERROR;
        }
        if (type == MZ_ZIP_EXTENSION_CDCD) {
            if (found || size != 8) {
                return MZ_FORMAT_ERROR;
            }
            found = 1;
            *entries = 0;
            for (int i = 0; i < 8; i++) {
                *entries |= (uint64_t)extra[offset + i] << (i * 8);
            }
        }
        offset += size;
    }
    if (!found) {
        return MZ_EXIST_ERROR;
    }
    uint64_t outer_count = 0;
    err = magiczip_count(a, &outer_count);
    if (err != MZ_OK) {
        return err;
    }
    /* CDCD replaces the outer directory with exactly one entry named "__cdcd__" (8 bytes). */
    if (outer_count != 1 || info->filename_size != 8 || memcmp(info->filename, "__cdcd__", 8) != 0 ||
        !(info->flag & MZ_ZIP_FLAG_ENCRYPTED) || info->aes_strength != MZ_AES_STRENGTH_256 ||
        (info->aes_version != 1 && info->aes_version != 2) ||
        (info->compression_method != MZ_COMPRESS_METHOD_STORE &&
         info->compression_method != MZ_COMPRESS_METHOD_DEFLATE) ||
        info->disk_number != 0 || mz_zip_entry_is_dir(a->zip) == MZ_OK) {
        return MZ_SUPPORT_ERROR;
    }
    return MZ_OK;
}

void magiczip_mask_headers(magiczip_archive *a) {
    a->secure = 1;
}

int32_t magiczip_catalog_write_begin(magiczip_archive *a, const char *password, int32_t *length) {
    void *cd = NULL;
    uint64_t count = 0;
    int32_t err = mz_zip_get_number_entry(a->zip, &count);
    if (err == MZ_OK) {
        err = mz_zip_get_cd_mem_stream(a->zip, &cd);
    }
    if (err != MZ_OK) {
        return err;
    }
    mz_stream_mem_get_buffer_length(cd, length);
    /* Application catalog budget, shared with SecureCatalog.swift and catalog_append below. */
    if (*length < 0 || *length > 64 * 1024 * 1024) {
        return MZ_BUF_ERROR;
    }
    /* 12 bytes = 2-byte ID 0xcdcd + 2-byte length 8 + uint64 count, all little-endian. */
    uint8_t extra[12] = {0xcd, 0xcd, 8, 0};
    for (int i = 0; i < 8; i++) {
        extra[4 + i] = (uint8_t)(count >> (i * 8));
    }
    mz_zip_file info = {0};
    info.filename = "__cdcd__";
    info.flag = MZ_ZIP_FLAG_UTF8;
    info.version_madeby = (MZ_HOST_SYSTEM_UNIX << 8) | 63;
    info.compression_method = MZ_COMPRESS_METHOD_STORE;
    info.uncompressed_size = *length;
    info.aes_version = 2;
    info.aes_strength = MZ_AES_STRENGTH_256;
    info.extrafield = extra;
    info.extrafield_size = sizeof(extra);
    err = mz_zip_entry_write_open(a->zip, &info, 0, 0, password);
    if (err == MZ_OK) {
        a->entry_open = 1;
    }
    return err;
}

int32_t magiczip_catalog_write_chunk(magiczip_archive *a, int32_t offset, int32_t count) {
    void *cd = NULL;
    const void *bytes = NULL;
    int32_t length = 0;
    int32_t err = mz_zip_get_cd_mem_stream(a->zip, &cd);
    if (err != MZ_OK) {
        return err;
    }
    mz_stream_mem_get_buffer_length(cd, &length);
    if (offset < 0 || count < 0 || offset > length || count > length - offset) {
        return MZ_PARAM_ERROR;
    }
    err = mz_stream_mem_get_buffer_at(cd, offset, &bytes);
    if (err != MZ_OK) {
        return err;
    }
    int32_t written = magiczip_write(a, bytes, count);
    return written == count ? MZ_OK : (written < 0 ? written : MZ_WRITE_ERROR);
}

int32_t magiczip_catalog_write_end(magiczip_archive *a) {
    void *cd = NULL;
    int32_t err = mz_zip_get_cd_mem_stream(a->zip, &cd);
    if (err == MZ_OK) {
        err = mz_stream_seek(cd, 0, MZ_SEEK_SET);
    }
    if (err != MZ_OK) {
        return err;
    }
    /* Discard plaintext directory before closing the outer catalog entry. */
    mz_stream_mem_set_buffer_limit(cd, 0);
    err = magiczip_write_close(a);
    if (err == MZ_OK) {
        err = mz_zip_set_number_entry(a->zip, 1);
    }
    return err;
}

int32_t magiczip_catalog_append(magiczip_archive *a, const void *bytes, int32_t count) {
    if (!a->catalog) {
        a->catalog = mz_stream_mem_create();
        if (!a->catalog) {
            return MZ_MEM_ERROR;
        }
        int32_t err = mz_stream_open(a->catalog, NULL, MZ_OPEN_MODE_CREATE);
        if (err != MZ_OK) {
            return err;
        }
    }
    int64_t size = mz_stream_tell(a->catalog);
    if (size < 0 || count < 0 || count > 64 * 1024 * 1024 - size) {
        return MZ_BUF_ERROR;
    }
    if (count == 0) {
        return MZ_OK;
    }
    int32_t written = mz_stream_write(a->catalog, bytes, count);
    return written == count ? MZ_OK : (written < 0 ? written : MZ_WRITE_ERROR);
}

int32_t magiczip_catalog_install(magiczip_archive *a, uint64_t entries) {
    if (a->entry_open) {
        return MZ_PARAM_ERROR;
    }
    int32_t err = magiczip_catalog_append(a, NULL, 0);
    if (err == MZ_OK) {
        err = mz_zip_set_cd_stream(a->zip, 0, a->catalog);
    }
    if (err == MZ_OK) {
        err = mz_zip_set_number_entry(a->zip, entries);
    }
    return err;
}
