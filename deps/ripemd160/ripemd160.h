#ifndef RIPEMD160_H
#define RIPEMD160_H

#include <stddef.h>
#include <stdint.h>

#define RIPEMD160_DIGEST_LENGTH 20

void ripemd160(const uint8_t *msg, size_t msg_len, uint8_t *digest);

#endif /* RIPEMD160_H */
