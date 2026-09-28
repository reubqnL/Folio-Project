#define _DEFAULT_SOURCE 1
#include "FolioRDMPrimitives.h"
#include <argon2.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <Security/SecRandom.h>
#else
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#endif

struct FolioSecret { unsigned char *bytes; size_t length, allocation; int locked; };
void folio_secure_zero(void *bytes, size_t length) {
    volatile unsigned char *p = bytes;
    if (!p) return;
    while (length--) *p++ = 0;
}
FolioSecret *folio_secret_create(size_t length) {
    if (!length || length > 4096) return NULL;
    long page = sysconf(_SC_PAGESIZE); if (page <= 0 || page > 1024 * 1024) return NULL;
    size_t allocation = ((length + (size_t)page - 1) / (size_t)page) * (size_t)page;
    FolioSecret *s = calloc(1, sizeof(*s)); if (!s) return NULL;
    void *memory = mmap(NULL, allocation, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) { free(s); return NULL; }
    s->bytes = memory; s->length = length; s->allocation = allocation;
    s->locked = mlock(memory, allocation) == 0;
#if defined(MADV_DONTDUMP)
    (void)madvise(memory, allocation, MADV_DONTDUMP);
#endif
    return s;
}
unsigned char *folio_secret_bytes(FolioSecret *s) { return s ? s->bytes : NULL; }
size_t folio_secret_length(const FolioSecret *s) { return s ? s->length : 0; }
int folio_secret_memory_locked(const FolioSecret *s) { return s ? s->locked : 0; }
void folio_secret_destroy(FolioSecret *s) {
    if (!s) return;
    if (s->bytes) {
        folio_secure_zero(s->bytes, s->allocation);
        if (s->locked) (void)munlock(s->bytes, s->allocation);
        (void)munmap(s->bytes, s->allocation);
    }
    folio_secure_zero(s, sizeof(*s)); free(s);
}
int folio_crypto_random(unsigned char *destination, size_t length) {
    if (!destination || !length || length > INT_MAX) return 0;
#if defined(__APPLE__)
    return SecRandomCopyBytes(kSecRandomDefault, length, destination) == errSecSuccess;
#else
    return RAND_bytes(destination, (int)length) == 1;
#endif
}
int folio_argon2id(const unsigned char *password, size_t password_length,
                   const unsigned char *salt, size_t salt_length,
                   uint32_t memory_kib, uint32_t iterations, uint32_t lanes,
                   unsigned char *output, size_t output_length) {
    if (!password || password_length == 0 || password_length > 1024 || !salt || salt_length != 16 ||
        !output || output_length != 32 || memory_kib != 65536 || iterations != 3 || lanes != 4) return 0;
    int result = argon2id_hash_raw(iterations, memory_kib, lanes, password, password_length,
                                  salt, salt_length, output, output_length);
    if (result != ARGON2_OK) folio_secure_zero(output, output_length);
    return result == ARGON2_OK;
}
int folio_argon2id_rfc9106_selftest(void) {
    unsigned char password[32], salt[16], secret[8], ad[12], output[32];
    const unsigned char expected[32] = {0x0d,0x64,0x0d,0xf5,0x8d,0x78,0x76,0x6c,0x08,0xc0,0x37,0xa3,0x4a,0x8b,0x53,0xc9,0xd0,0x1e,0xf0,0x45,0x2d,0x75,0xb6,0x5e,0xb5,0x25,0x20,0xe9,0x6b,0x01,0xe6,0x59};
    memset(password, 1, sizeof(password)); memset(salt, 2, sizeof(salt));
    memset(secret, 3, sizeof(secret)); memset(ad, 4, sizeof(ad)); memset(output, 0, sizeof(output));
    argon2_context context = {0};
    context.out = output; context.outlen = 32; context.pwd = password; context.pwdlen = 32;
    context.salt = salt; context.saltlen = 16; context.secret = secret; context.secretlen = 8;
    context.ad = ad; context.adlen = 12; context.t_cost = 3; context.m_cost = 32;
    context.lanes = 4; context.threads = 1; context.version = ARGON2_VERSION_13;
    int result = argon2id_ctx(&context) == ARGON2_OK && memcmp(output, expected, 32) == 0;
    folio_secure_zero(password, sizeof(password)); folio_secure_zero(secret, sizeof(secret)); folio_secure_zero(output, sizeof(output));
    return result;
}

#if !defined(__APPLE__)
int folio_aes256gcm_seal(const unsigned char *key, const unsigned char *nonce,
                        const unsigned char *plain, size_t length,
                        const unsigned char *aad, size_t aad_length,
                        unsigned char *cipher, unsigned char *tag) {
    if (!key || !nonce || !tag || length > 64 * 1024 * 1024 || aad_length > 65536 ||
        (length && (!plain || !cipher)) || (aad_length && !aad)) return 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); if (!ctx) return 0;
    unsigned char dummy[16] = {0}; unsigned char *destination = cipher ? cipher : dummy;
    int count = 0, tail = 0, ok = 0;
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1) goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1) goto done;
    if (EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) != 1) goto done;
    if (aad_length && EVP_EncryptUpdate(ctx, NULL, &count, aad, (int)aad_length) != 1) goto done;
    if (length && EVP_EncryptUpdate(ctx, destination, &count, plain, (int)length) != 1) goto done;
    if (!length) count = 0;
    if (EVP_EncryptFinal_ex(ctx, destination + count, &tail) != 1) goto done;
    if ((size_t)(count + tail) != length) goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1) goto done;
    ok = 1;
done:
    if (!ok) { folio_secure_zero(cipher, length); folio_secure_zero(tag, 16); }
    folio_secure_zero(dummy, sizeof(dummy)); EVP_CIPHER_CTX_free(ctx); return ok;
}
int folio_aes256gcm_open(const unsigned char *key, const unsigned char *nonce,
                        const unsigned char *cipher, size_t length,
                        const unsigned char *aad, size_t aad_length,
                        const unsigned char *tag, unsigned char *plain) {
    if (!key || !nonce || !tag || length > 64 * 1024 * 1024 || aad_length > 65536 ||
        (length && (!cipher || !plain)) || (aad_length && !aad)) return 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); if (!ctx) return 0;
    unsigned char dummy[16] = {0}; unsigned char *destination = plain ? plain : dummy;
    int count = 0, tail = 0, ok = 0;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1) goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1) goto done;
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) != 1) goto done;
    if (aad_length && EVP_DecryptUpdate(ctx, NULL, &count, aad, (int)aad_length) != 1) goto done;
    if (length && EVP_DecryptUpdate(ctx, destination, &count, cipher, (int)length) != 1) goto done;
    if (!length) count = 0;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag) != 1) goto done;
    if (EVP_DecryptFinal_ex(ctx, destination + count, &tail) != 1) goto done;
    if ((size_t)(count + tail) != length) goto done;
    ok = 1;
done:
    if (!ok) folio_secure_zero(plain, length); /* Unauthenticated bytes never escape. */
    folio_secure_zero(dummy, sizeof(dummy)); EVP_CIPHER_CTX_free(ctx); return ok;
}
int folio_hkdf_sha256(const unsigned char *input, size_t input_length,
                      const unsigned char *salt, size_t salt_length,
                      const unsigned char *info, size_t info_length,
                      unsigned char *output, size_t output_length) {
    if (!input || !input_length || input_length > 4096 || salt_length > 1024 || info_length > 4096 ||
        !output || !output_length || output_length > 64 || (salt_length && !salt) || (info_length && !info)) return 0;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL); if (!ctx) return 0;
    size_t length = output_length; int ok = 0;
    if (EVP_PKEY_derive_init(ctx) <= 0 || EVP_PKEY_CTX_set_hkdf_md(ctx, EVP_sha256()) <= 0) goto done;
    if (EVP_PKEY_CTX_set1_hkdf_salt(ctx, salt, (int)salt_length) <= 0 || EVP_PKEY_CTX_set1_hkdf_key(ctx, input, (int)input_length) <= 0) goto done;
    if (info_length && EVP_PKEY_CTX_add1_hkdf_info(ctx, info, (int)info_length) <= 0) goto done;
    if (EVP_PKEY_derive(ctx, output, &length) <= 0 || length != output_length) goto done;
    ok = 1;
done:
    if (!ok) folio_secure_zero(output, output_length);
    EVP_PKEY_CTX_free(ctx); return ok;
}
const char *folio_crypto_backend_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
#else
/* Never selected by the Mac Swift adapter, which uses public CryptoKit APIs. */
int folio_aes256gcm_seal(const unsigned char *k,const unsigned char *n,const unsigned char *p,size_t l,const unsigned char *a,size_t al,unsigned char *c,unsigned char *t) { (void)k;(void)n;(void)p;(void)l;(void)a;(void)al;(void)c;(void)t;return 0; }
int folio_aes256gcm_open(const unsigned char *k,const unsigned char *n,const unsigned char *c,size_t l,const unsigned char *a,size_t al,const unsigned char *t,unsigned char *p) { (void)k;(void)n;(void)c;(void)l;(void)a;(void)al;(void)t;(void)p;return 0; }
int folio_hkdf_sha256(const unsigned char *i,size_t il,const unsigned char *s,size_t sl,const unsigned char *n,size_t nl,unsigned char *o,size_t ol) { (void)i;(void)il;(void)s;(void)sl;(void)n;(void)nl;(void)o;(void)ol;return 0; }
const char *folio_crypto_backend_version(void) { return "CryptoKit / Security.framework (native adapter)"; }
#endif
