#ifndef FOLIO_RDM_PRIMITIVES_H
#define FOLIO_RDM_PRIMITIVES_H
#include <stddef.h>
#include <stdint.h>

typedef struct FolioSecret FolioSecret;
FolioSecret *folio_secret_create(size_t length);
unsigned char *folio_secret_bytes(FolioSecret *secret);
size_t folio_secret_length(const FolioSecret *secret);
int folio_secret_memory_locked(const FolioSecret *secret);
void folio_secret_destroy(FolioSecret *secret);
void folio_secure_zero(void *bytes, size_t length);
int folio_crypto_random(unsigned char *destination, size_t length);
/* Argon2id v1.3; production call sites accept only the fixed protocol profile. */
int folio_argon2id(const unsigned char *password, size_t password_length,
                   const unsigned char *salt, size_t salt_length,
                   uint32_t memory_kib, uint32_t iterations, uint32_t lanes,
                   unsigned char *output, size_t output_length);
int folio_argon2id_rfc9106_selftest(void);
/* Linux CI adapter. Mac uses CryptoKit for AES-GCM and HKDF. */
int folio_aes256gcm_seal(const unsigned char *key, const unsigned char *nonce,
                        const unsigned char *plain, size_t length,
                        const unsigned char *aad, size_t aad_length,
                        unsigned char *cipher, unsigned char *tag);
int folio_aes256gcm_open(const unsigned char *key, const unsigned char *nonce,
                        const unsigned char *cipher, size_t length,
                        const unsigned char *aad, size_t aad_length,
                        const unsigned char *tag, unsigned char *plain);
int folio_hkdf_sha256(const unsigned char *input, size_t input_length,
                      const unsigned char *salt, size_t salt_length,
                      const unsigned char *info, size_t info_length,
                      unsigned char *output, size_t output_length);
const char *folio_crypto_backend_version(void);

typedef struct { char *name; unsigned char *bytes; size_t length; } FolioZipMember;
int folio_rdm_zip_write(const FolioZipMember *members, size_t count, size_t maximum_bytes,
                        unsigned char **output, size_t *output_length);
int folio_rdm_zip_read(const unsigned char *archive_bytes, size_t length,
                       size_t maximum_entries, size_t maximum_member_bytes, size_t maximum_total_bytes,
                       FolioZipMember **members, size_t *count);
void folio_rdm_zip_free(FolioZipMember *members, size_t count);
void folio_rdm_bytes_free(void *bytes);
const char *folio_archive_backend_version(void);
#endif
