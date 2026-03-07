// C wrapper for Bitcoin Core's multi-backend SHA-256.
// Links against CSHA256 class and SHA256D64 function.

#include "sha256_c.h"
#include "crypto/sha256.h"

#include <cstring>

static const char* detected_impl = nullptr;

extern "C" {

const char* sha256_autodetect(void) {
    static char impl_buf[128];
    std::string result = SHA256AutoDetect();
    size_t len = result.size();
    if (len >= sizeof(impl_buf)) len = sizeof(impl_buf) - 1;
    memcpy(impl_buf, result.c_str(), len);
    impl_buf[len] = 0;
    detected_impl = impl_buf;
    return detected_impl;
}

void sha256_init(sha256_ctx* ctx) {
    // Placement-construct CSHA256 into the ctx buffer.
    // sha256_ctx layout matches CSHA256 exactly.
    new (ctx) CSHA256();
}

void sha256_update(sha256_ctx* ctx, const unsigned char* data, size_t len) {
    reinterpret_cast<CSHA256*>(ctx)->Write(data, len);
}

void sha256_finalize(sha256_ctx* ctx, unsigned char hash[32]) {
    reinterpret_cast<CSHA256*>(ctx)->Finalize(hash);
}

void sha256_reset(sha256_ctx* ctx) {
    reinterpret_cast<CSHA256*>(ctx)->Reset();
}

void sha256_hash(const unsigned char* data, size_t len, unsigned char hash[32]) {
    CSHA256().Write(data, len).Finalize(hash);
}

void sha256d(const unsigned char* data, size_t len, unsigned char hash[32]) {
    unsigned char first[32];
    CSHA256().Write(data, len).Finalize(first);
    CSHA256().Write(first, 32).Finalize(hash);
}

void sha256d_multi(const unsigned char** parts, const size_t* lengths, size_t count, unsigned char hash[32]) {
    unsigned char first[32];
    CSHA256 ctx;
    for (size_t i = 0; i < count; i++) {
        ctx.Write(parts[i], lengths[i]);
    }
    ctx.Finalize(first);
    CSHA256().Write(first, 32).Finalize(hash);
}

void sha256d64(unsigned char* output, const unsigned char* input, size_t blocks) {
    SHA256D64(output, input, blocks);
}

} // extern "C"
