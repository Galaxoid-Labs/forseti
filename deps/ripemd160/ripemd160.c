/*
 * RIPEMD-160 implementation based on the reference implementation
 * from the original RIPEMD-160 specification by Hans Dobbertin,
 * Antoon Bosselaers, and Bart Preneel.
 *
 * This is a clean, minimal implementation for use in Bitcoin address
 * derivation (HASH160 = RIPEMD160(SHA256(x))).
 */

#include "ripemd160.h"
#include <string.h>

/* Rotate left 32-bit */
#define ROL(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

/* Boolean functions */
#define F(x, y, z) ((x) ^ (y) ^ (z))
#define G(x, y, z) (((x) & (y)) | (~(x) & (z)))
#define H(x, y, z) (((x) | ~(y)) ^ (z))
#define I(x, y, z) (((x) & (z)) | ((y) & ~(z)))
#define J(x, y, z) ((x) ^ ((y) | ~(z)))

/* Round constants */
#define K0  0x00000000u
#define K1  0x5a827999u
#define K2  0x6ed9eba1u
#define K3  0x8f1bbcdcu
#define K4  0xa953fd4eu
#define KK0 0x50a28be6u
#define KK1 0x5c4dd124u
#define KK2 0x6d703ef3u
#define KK3 0x7a6d76e9u
#define KK4 0x00000000u

static void ripemd160_compress(uint32_t *state, const uint8_t *block) {
    uint32_t al, bl, cl, dl, el;
    uint32_t ar, br, cr, dr, er;
    uint32_t t;
    uint32_t w[16];

    /* Parse block into 16 little-endian 32-bit words */
    for (int i = 0; i < 16; i++) {
        w[i] = (uint32_t)block[i * 4]
             | ((uint32_t)block[i * 4 + 1] << 8)
             | ((uint32_t)block[i * 4 + 2] << 16)
             | ((uint32_t)block[i * 4 + 3] << 24);
    }

    al = ar = state[0];
    bl = br = state[1];
    cl = cr = state[2];
    dl = dr = state[3];
    el = er = state[4];

    /* Message word selection (left rounds) */
    static const int rl[80] = {
         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
         7,  4, 13,  1, 10,  6, 15,  3, 12,  0,  9,  5,  2, 14, 11,  8,
         3, 10, 14,  4,  9, 15,  8,  1,  2,  7,  0,  6, 13, 11,  5, 12,
         1,  9, 11, 10,  0,  8, 12,  4, 13,  3,  7, 15, 14,  5,  6,  2,
         4,  0,  5,  9,  7, 12,  2, 10, 14,  1,  3,  8, 11,  6, 15, 13
    };

    /* Message word selection (right rounds) */
    static const int rr[80] = {
         5, 14,  7,  0,  9,  2, 11,  4, 13,  6, 15,  8,  1, 10,  3, 12,
         6, 11,  3,  7,  0, 13,  5, 10, 14, 15,  8, 12,  4,  9,  1,  2,
        15,  5,  1,  3,  7, 14,  6,  9, 11,  8, 12,  2, 10,  0,  4, 13,
         8,  6,  4,  1,  3, 11, 15,  0,  5, 12,  2, 13,  9,  7, 10, 14,
        12, 15, 10,  4,  1,  5,  8,  7,  6,  2, 13, 14,  0,  3,  9, 11
    };

    /* Rotate amounts (left rounds) */
    static const int sl[80] = {
        11, 14, 15, 12,  5,  8,  7,  9, 11, 13, 14, 15,  6,  7,  9,  8,
         7,  6,  8, 13, 11,  9,  7, 15,  7, 12, 15,  9, 11,  7, 13, 12,
        11, 13,  6,  7, 14,  9, 13, 15, 14,  8, 13,  6,  5, 12,  7,  5,
        11, 12, 14, 15, 14, 15,  9,  8,  9, 14,  5,  6,  8,  6,  5, 12,
         9, 15,  5, 11,  6,  8, 13, 12,  5, 12, 13, 14, 11,  8,  5,  6
    };

    /* Rotate amounts (right rounds) */
    static const int sr[80] = {
         8,  9,  9, 11, 13, 15, 15,  5,  7,  7,  8, 11, 14, 14, 12,  6,
         9, 13, 15,  7, 12,  8,  9, 11,  7,  7, 12,  7,  6, 15, 13, 11,
         9,  7, 15, 11,  8,  6,  6, 14, 12, 13,  5, 14, 13, 13,  7,  5,
        15,  5,  8, 11, 14, 14,  6, 14,  6,  9, 12,  9, 12,  5, 15,  8,
         8,  5, 12,  9, 12,  5, 14,  6,  8, 13,  6,  5, 15, 13, 11, 11
    };

    /* 80 rounds, left and right in parallel */
    for (int j = 0; j < 80; j++) {
        /* Left round */
        if (j < 16)
            t = F(bl, cl, dl) + K0;
        else if (j < 32)
            t = G(bl, cl, dl) + K1;
        else if (j < 48)
            t = H(bl, cl, dl) + K2;
        else if (j < 64)
            t = I(bl, cl, dl) + K3;
        else
            t = J(bl, cl, dl) + K4;
        t += al + w[rl[j]];
        t = ROL(t, sl[j]) + el;
        al = el; el = dl; dl = ROL(cl, 10); cl = bl; bl = t;

        /* Right round */
        if (j < 16)
            t = J(br, cr, dr) + KK0;
        else if (j < 32)
            t = I(br, cr, dr) + KK1;
        else if (j < 48)
            t = H(br, cr, dr) + KK2;
        else if (j < 64)
            t = G(br, cr, dr) + KK3;
        else
            t = F(br, cr, dr) + KK4;
        t += ar + w[rr[j]];
        t = ROL(t, sr[j]) + er;
        ar = er; er = dr; dr = ROL(cr, 10); cr = br; br = t;
    }

    t = state[1] + cl + dr;
    state[1] = state[2] + dl + er;
    state[2] = state[3] + el + ar;
    state[3] = state[4] + al + br;
    state[4] = state[0] + bl + cr;
    state[0] = t;
}

void ripemd160(const uint8_t *msg, size_t msg_len, uint8_t *digest) {
    uint32_t state[5] = {
        0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u, 0xc3d2e1f0u
    };

    /* Process complete 64-byte blocks */
    size_t i;
    for (i = 0; i + 64 <= msg_len; i += 64) {
        ripemd160_compress(state, msg + i);
    }

    /* Final block with padding */
    uint8_t block[64];
    size_t remaining = msg_len - i;
    memcpy(block, msg + i, remaining);
    block[remaining] = 0x80;

    if (remaining >= 56) {
        memset(block + remaining + 1, 0, 63 - remaining);
        ripemd160_compress(state, block);
        memset(block, 0, 56);
    } else {
        memset(block + remaining + 1, 0, 55 - remaining);
    }

    /* Append length in bits as 64-bit little-endian */
    uint64_t bit_len = (uint64_t)msg_len * 8;
    block[56] = (uint8_t)(bit_len);
    block[57] = (uint8_t)(bit_len >> 8);
    block[58] = (uint8_t)(bit_len >> 16);
    block[59] = (uint8_t)(bit_len >> 24);
    block[60] = (uint8_t)(bit_len >> 32);
    block[61] = (uint8_t)(bit_len >> 40);
    block[62] = (uint8_t)(bit_len >> 48);
    block[63] = (uint8_t)(bit_len >> 56);
    ripemd160_compress(state, block);

    /* Output digest in little-endian */
    for (int j = 0; j < 5; j++) {
        digest[j * 4]     = (uint8_t)(state[j]);
        digest[j * 4 + 1] = (uint8_t)(state[j] >> 8);
        digest[j * 4 + 2] = (uint8_t)(state[j] >> 16);
        digest[j * 4 + 3] = (uint8_t)(state[j] >> 24);
    }
}
