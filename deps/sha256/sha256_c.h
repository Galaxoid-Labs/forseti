// C wrapper for Bitcoin Core's multi-backend SHA-256.
// Provides extern "C" functions for FFI from Odin.

#ifndef SHA256_C_H
#define SHA256_C_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque SHA-256 context (matches sizeof(CSHA256) = 32+64+8 = 104 bytes)
typedef struct {
    uint32_t s[8];
    unsigned char buf[64];
    uint64_t bytes;
} sha256_ctx;

// Initialize autodetection — call once at startup.
// Returns a static string describing the selected implementation.
const char* sha256_autodetect(void);

// Streaming API
void sha256_init(sha256_ctx* ctx);
void sha256_update(sha256_ctx* ctx, const unsigned char* data, size_t len);
void sha256_finalize(sha256_ctx* ctx, unsigned char hash[32]);
void sha256_reset(sha256_ctx* ctx);

// Convenience: single-shot SHA-256
void sha256_hash(const unsigned char* data, size_t len, unsigned char hash[32]);

// Convenience: double SHA-256 (SHA-256d)
void sha256d(const unsigned char* data, size_t len, unsigned char hash[32]);

// Convenience: double SHA-256 of multiple parts (no concatenation needed)
void sha256d_multi(const unsigned char** parts, const size_t* lengths, size_t count, unsigned char hash[32]);

// Parallel double-SHA256 of 64-byte blocks (for Merkle tree).
// output: blocks*32 bytes, input: blocks*64 bytes
void sha256d64(unsigned char* output, const unsigned char* input, size_t blocks);

#ifdef __cplusplus
}
#endif

#endif // SHA256_C_H
