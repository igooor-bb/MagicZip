#ifndef MAGICZIP_CMINIZIP_H
#define MAGICZIP_CMINIZIP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct magiczip_archive magiczip_archive;
typedef struct {
    const char *name;
    uint16_t name_length;
    uint16_t method;
    uint16_t flags;
    uint16_t aes_version;
    uint8_t aes_strength;
    uint8_t directory;
    uint8_t symlink;
    uint32_t attributes;
    uint16_t made_by;
    int64_t compressed_size;
    int64_t uncompressed_size;
    int64_t modified;
    int64_t position;
    uint32_t crc;
    uint32_t disk;
} magiczip_info;
/* Private Swift adapter ABI; never exposed in MagicZip's public Swift API.
   open takes ownership of fd on both success and failure. */
int32_t magiczip_open(int fd, int writing, magiczip_archive **archive);
int32_t magiczip_close(magiczip_archive **archive);
int32_t magiczip_first(magiczip_archive *archive);
int32_t magiczip_next(magiczip_archive *archive);
int32_t magiczip_seek(magiczip_archive *archive, int64_t position);
int32_t magiczip_count(magiczip_archive *archive, uint64_t *count);
int32_t magiczip_metadata(magiczip_archive *archive, magiczip_info *info);
int32_t magiczip_read_open(magiczip_archive *archive, const char *password);
int32_t magiczip_read(magiczip_archive *archive, void *buffer, int32_t count);
int32_t magiczip_read_close(magiczip_archive *archive, int verify);
int32_t magiczip_write_open(magiczip_archive *archive, const char *path, int directory, int16_t method,
                            int16_t level, int64_t modified, const char *password);
int32_t magiczip_write(magiczip_archive *archive, const void *buffer, int32_t count);
int32_t magiczip_write_close(magiczip_archive *archive);
#ifdef __cplusplus
}
#endif
#endif
