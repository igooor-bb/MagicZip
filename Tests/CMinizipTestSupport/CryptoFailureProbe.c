/* Exercise the real AES stream with failures isolated to this test translation unit. */
#include "include/SecurityProbe.h"
#include "../../Sources/CMinizip/vendor/mz.h"
#include "../../Sources/CMinizip/vendor/mz_crypt.h"
#include "../../Sources/CMinizip/vendor/mz_strm.h"
#include "../../Sources/CMinizip/vendor/mz_strm_mem.h"
#include <stdbool.h>

/* Values are shared with the parameterized Swift test; keep their numbering stable. */
typedef enum {
    CRYPTO_FAILURE_NONE = 0,
    CRYPTO_FAILURE_RANDOM = 1,
    CRYPTO_FAILURE_PBKDF2 = 2,
    CRYPTO_FAILURE_AES_KEY = 3,
    CRYPTO_FAILURE_HMAC_INIT = 4,
    CRYPTO_FAILURE_AES_ENCRYPT = 5,
    CRYPTO_FAILURE_HMAC_UPDATE = 6,
    CRYPTO_FAILURE_HMAC_END = 7,
    CRYPTO_FAILURE_AES_SHORT_OUTPUT = 8,
} crypto_failure_stage;

static const char payload[] = "private";

enum {
    PAYLOAD_SIZE = sizeof(payload) - 1,
    AES_HEADER_SIZE = 16 + 2, /* AES-256 salt and password verifier. */
    AES_AUTH_CODE_SIZE = 10,
    ENCRYPTED_ENTRY_SIZE = AES_HEADER_SIZE + PAYLOAD_SIZE + AES_AUTH_CODE_SIZE,
};

/* Swift Testing may run probe invocations concurrently on different threads. */
static _Thread_local crypto_failure_stage active_failure;

/* These wrappers are defined before macro substitution, so fallbacks call the real primitives. */
static int32_t failing_rand(uint8_t *buffer, int32_t size) {
    return active_failure == CRYPTO_FAILURE_RANDOM ? 0 : mz_crypt_rand(buffer, size);
}

static int32_t failing_pbkdf2(const uint8_t *password, int32_t password_length, const uint8_t *salt,
                              int32_t salt_length, uint32_t iterations, uint8_t *key, uint16_t key_length) {
    if (active_failure == CRYPTO_FAILURE_PBKDF2) {
        memset(key, 0, key_length);
        return MZ_MEM_ERROR;
    }
    return mz_crypt_pbkdf2(password, password_length, salt, salt_length, iterations, key, key_length);
}

static int32_t failing_key(void *handle, const void *key, int32_t key_length, const void *iv,
                           int32_t iv_length) {
    if (active_failure == CRYPTO_FAILURE_AES_KEY) {
        return MZ_HASH_ERROR;
    }
    return mz_crypt_aes_set_encrypt_key(handle, key, key_length, iv, iv_length);
}

static int32_t failing_hmac_init(void *handle, const void *key, int32_t key_length) {
    if (active_failure == CRYPTO_FAILURE_HMAC_INIT) {
        return MZ_CRYPT_ERROR;
    }
    return mz_crypt_hmac_init(handle, key, key_length);
}

static int32_t failing_encrypt(void *handle, const void *aad, int32_t aad_size, uint8_t *buffer,
                               int32_t size) {
    if (active_failure == CRYPTO_FAILURE_AES_ENCRYPT) {
        return MZ_CRYPT_ERROR;
    }
    if (active_failure == CRYPTO_FAILURE_AES_SHORT_OUTPUT) {
        return 0;
    }
    return mz_crypt_aes_encrypt(handle, aad, aad_size, buffer, size);
}

static int32_t failing_hmac_update(void *handle, const void *buffer, int32_t size) {
    if (active_failure == CRYPTO_FAILURE_HMAC_UPDATE) {
        return MZ_CRYPT_ERROR;
    }
    return mz_crypt_hmac_update(handle, buffer, size);
}

static int32_t failing_hmac_end(void *handle, uint8_t *digest, int32_t size) {
    if (active_failure == CRYPTO_FAILURE_HMAC_END) {
        return MZ_CRYPT_ERROR;
    }
    return mz_crypt_hmac_end(handle, digest, size);
}

/* Substitute primitives only in the included AES implementation below. */
#undef mz_crypt_rand
#define mz_crypt_rand failing_rand
#undef mz_crypt_pbkdf2
#define mz_crypt_pbkdf2 failing_pbkdf2
#undef mz_crypt_aes_set_encrypt_key
#define mz_crypt_aes_set_encrypt_key failing_key
#undef mz_crypt_aes_encrypt
#define mz_crypt_aes_encrypt failing_encrypt
#undef mz_crypt_hmac_init
#define mz_crypt_hmac_init failing_hmac_init
#undef mz_crypt_hmac_update
#define mz_crypt_hmac_update failing_hmac_update
#undef mz_crypt_hmac_end
#define mz_crypt_hmac_end failing_hmac_end
/* Give the included AES implementation its own symbols so it can coexist with the SDK. */
#undef mz_stream_wzaes_open
#define mz_stream_wzaes_open magiczip_test_mz_stream_wzaes_open
#undef mz_stream_wzaes_is_open
#define mz_stream_wzaes_is_open magiczip_test_mz_stream_wzaes_is_open
#undef mz_stream_wzaes_read
#define mz_stream_wzaes_read magiczip_test_mz_stream_wzaes_read
#undef mz_stream_wzaes_write
#define mz_stream_wzaes_write magiczip_test_mz_stream_wzaes_write
#undef mz_stream_wzaes_tell
#define mz_stream_wzaes_tell magiczip_test_mz_stream_wzaes_tell
#undef mz_stream_wzaes_seek
#define mz_stream_wzaes_seek magiczip_test_mz_stream_wzaes_seek
#undef mz_stream_wzaes_close
#define mz_stream_wzaes_close magiczip_test_mz_stream_wzaes_close
#undef mz_stream_wzaes_error
#define mz_stream_wzaes_error magiczip_test_mz_stream_wzaes_error
#undef mz_stream_wzaes_set_password
#define mz_stream_wzaes_set_password magiczip_test_mz_stream_wzaes_set_password
#undef mz_stream_wzaes_set_strength
#define mz_stream_wzaes_set_strength magiczip_test_mz_stream_wzaes_set_strength
#undef mz_stream_wzaes_get_prop_int64
#define mz_stream_wzaes_get_prop_int64 magiczip_test_mz_stream_wzaes_get_prop_int64
#undef mz_stream_wzaes_set_prop_int64
#define mz_stream_wzaes_set_prop_int64 magiczip_test_mz_stream_wzaes_set_prop_int64
#undef mz_stream_wzaes_create
#define mz_stream_wzaes_create magiczip_test_mz_stream_wzaes_create
#undef mz_stream_wzaes_delete
#define mz_stream_wzaes_delete magiczip_test_mz_stream_wzaes_delete
#undef mz_stream_wzaes_get_interface
#define mz_stream_wzaes_get_interface magiczip_test_mz_stream_wzaes_get_interface

#include "../../Sources/CMinizip/vendor/mz_strm_wzaes.c"

/* Build valid encrypted input before enabling any failure in the read scenario. */
static int32_t prepare_encrypted_input(void *aes, void *memory) {
    int32_t status = mz_stream_open(aes, "password", MZ_OPEN_MODE_WRITE);
    if (status != MZ_OK) {
        return status;
    }
    if (mz_stream_write(aes, payload, PAYLOAD_SIZE) != PAYLOAD_SIZE) {
        return MZ_WRITE_ERROR;
    }
    status = mz_stream_close(aes);
    if (status != MZ_OK) {
        return status;
    }
    mz_stream_seek(memory, 0, MZ_SEEK_SET);
    mz_stream_set_prop_int64(aes, MZ_STREAM_PROP_TOTAL_IN_MAX, ENCRYPTED_ENTRY_SIZE);
    return MZ_OK;
}

static int32_t run_entry_operation(void *aes, bool reading) {
    int32_t status = mz_stream_open(aes, "password", reading ? MZ_OPEN_MODE_READ : MZ_OPEN_MODE_WRITE);
    if (status != MZ_OK) {
        return status;
    }

    char buffer[PAYLOAD_SIZE];
    int32_t result =
        reading ? mz_stream_read(aes, buffer, sizeof(buffer)) : mz_stream_write(aes, payload, PAYLOAD_SIZE);
    return result < 0 ? result : mz_stream_close(aes);
}

static int32_t expected_error(crypto_failure_stage stage) {
    switch (stage) {
    case CRYPTO_FAILURE_PBKDF2:
        return MZ_MEM_ERROR;
    case CRYPTO_FAILURE_AES_KEY:
        return MZ_HASH_ERROR;
    default:
        return MZ_CRYPT_ERROR;
    }
}

static int32_t expected_output_size(crypto_failure_stage stage) {
    switch (stage) {
    case CRYPTO_FAILURE_RANDOM:
    case CRYPTO_FAILURE_PBKDF2:
    case CRYPTO_FAILURE_AES_KEY:
    case CRYPTO_FAILURE_HMAC_INIT:
        return 0; /* Failed setup must not write a header. */
    case CRYPTO_FAILURE_HMAC_END:
        return AES_HEADER_SIZE + PAYLOAD_SIZE; /* Failed close must not write a MAC. */
    default:
        return AES_HEADER_SIZE; /* Failed payload processing must not write ciphertext. */
    }
}

int32_t magiczip_test_crypto_failure(int stage, int reading) {
    bool passed = false;
    active_failure = CRYPTO_FAILURE_NONE;
    void *memory = mz_stream_mem_create();
    void *aes = mz_stream_wzaes_create();

    /* Prepare streams while all cryptographic primitives still work normally. */
    if (mz_stream_open(memory, NULL, MZ_OPEN_MODE_CREATE) != MZ_OK) {
        goto cleanup;
    }
    mz_stream_set_base(aes, memory);
    if (reading && prepare_encrypted_input(aes, memory) != MZ_OK) {
        goto cleanup;
    }

    /* Trigger the selected failure and check both the status and visible output. */
    active_failure = (crypto_failure_stage)stage;
    int32_t expected_status = expected_error(active_failure);
    passed = run_entry_operation(aes, reading) == expected_status;
    if (passed && !reading) {
        int32_t output_size = 0;
        mz_stream_mem_get_buffer_length(memory, &output_size);
        passed = output_size == expected_output_size(active_failure);
    }
    if (passed && active_failure >= CRYPTO_FAILURE_AES_ENCRYPT) {
        /* A later close must preserve a payload/finalization failure. */
        passed = mz_stream_close(aes) == expected_status;
    }

cleanup:
    active_failure = CRYPTO_FAILURE_NONE;
    mz_stream_delete(&aes);
    mz_stream_delete(&memory);
    return passed;
}
