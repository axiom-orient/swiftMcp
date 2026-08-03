#include "MCPPlatformCrypto.h"

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>

int mcp_sha256(const uint8_t *input, size_t input_length, uint8_t output[32]) {
    if (input_length > UINT32_MAX) return -1;
    return CC_SHA256(input, (CC_LONG)input_length, output) != NULL ? 0 : -1;
}

int mcp_secure_random(uint8_t *output, size_t output_length) {
    return SecRandomCopyBytes(kSecRandomDefault, output_length, output) == errSecSuccess ? 0 : -1;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/random.h>
#endif

typedef struct {
    uint32_t state[8];
    uint64_t length_bits;
    uint8_t block[64];
    size_t block_length;
} mcp_sha256_context;

static const uint32_t mcp_sha256_constants[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U,
    0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U,
    0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
    0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU,
    0x5b9cca4fU, 0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

static uint32_t mcp_rotr32(uint32_t value, uint32_t count) {
    return (value >> count) | (value << (32U - count));
}

static void mcp_sha256_compress(mcp_sha256_context *context, const uint8_t block[64]) {
    uint32_t words[64];
    for (size_t index = 0; index < 16; index++) {
        words[index] = ((uint32_t)block[index * 4] << 24)
            | ((uint32_t)block[index * 4 + 1] << 16)
            | ((uint32_t)block[index * 4 + 2] << 8)
            | (uint32_t)block[index * 4 + 3];
    }
    for (size_t index = 16; index < 64; index++) {
        uint32_t sigma0 = mcp_rotr32(words[index - 15], 7) ^ mcp_rotr32(words[index - 15], 18)
            ^ (words[index - 15] >> 3);
        uint32_t sigma1 = mcp_rotr32(words[index - 2], 17) ^ mcp_rotr32(words[index - 2], 19)
            ^ (words[index - 2] >> 10);
        words[index] = words[index - 16] + sigma0 + words[index - 7] + sigma1;
    }

    uint32_t a = context->state[0];
    uint32_t b = context->state[1];
    uint32_t c = context->state[2];
    uint32_t d = context->state[3];
    uint32_t e = context->state[4];
    uint32_t f = context->state[5];
    uint32_t g = context->state[6];
    uint32_t h = context->state[7];
    for (size_t index = 0; index < 64; index++) {
        uint32_t sum1 = mcp_rotr32(e, 6) ^ mcp_rotr32(e, 11) ^ mcp_rotr32(e, 25);
        uint32_t choice = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + sum1 + choice + mcp_sha256_constants[index] + words[index];
        uint32_t sum0 = mcp_rotr32(a, 2) ^ mcp_rotr32(a, 13) ^ mcp_rotr32(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

static void mcp_sha256_update(mcp_sha256_context *context, const uint8_t *input, size_t input_length) {
    for (size_t index = 0; index < input_length; index++) {
        context->block[context->block_length++] = input[index];
        if (context->block_length == sizeof(context->block)) {
            mcp_sha256_compress(context, context->block);
            context->length_bits += 512U;
            context->block_length = 0;
        }
    }
}

static void mcp_sha256_finalize(mcp_sha256_context *context, uint8_t output[32]) {
    context->length_bits += (uint64_t)context->block_length * 8U;
    context->block[context->block_length++] = 0x80U;
    if (context->block_length > 56) {
        while (context->block_length < 64) context->block[context->block_length++] = 0;
        mcp_sha256_compress(context, context->block);
        context->block_length = 0;
    }
    while (context->block_length < 56) context->block[context->block_length++] = 0;
    for (size_t index = 0; index < 8; index++) {
        context->block[56 + index] = (uint8_t)(context->length_bits >> (56U - (uint32_t)index * 8U));
    }
    mcp_sha256_compress(context, context->block);
    for (size_t index = 0; index < 8; index++) {
        output[index * 4] = (uint8_t)(context->state[index] >> 24);
        output[index * 4 + 1] = (uint8_t)(context->state[index] >> 16);
        output[index * 4 + 2] = (uint8_t)(context->state[index] >> 8);
        output[index * 4 + 3] = (uint8_t)context->state[index];
    }
}

int mcp_sha256(const uint8_t *input, size_t input_length, uint8_t output[32]) {
    if ((input == NULL && input_length != 0) || output == NULL) return -1;
    mcp_sha256_context context = {
        .state = { 0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
                   0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U },
        .length_bits = 0,
        .block = { 0 },
        .block_length = 0,
    };
    mcp_sha256_update(&context, input, input_length);
    mcp_sha256_finalize(&context, output);
    return 0;
}

int mcp_secure_random(uint8_t *output, size_t output_length) {
    if (output == NULL && output_length != 0) return -1;
    size_t offset = 0;
#if defined(__linux__)
    while (offset < output_length) {
        ssize_t count = getrandom(output + offset, output_length - offset, 0);
        if (count > 0) {
            offset += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    if (offset == output_length) return 0;
#endif
    int descriptor = open("/dev/urandom", O_RDONLY);
    if (descriptor < 0) return -1;
    while (offset < output_length) {
        ssize_t count = read(descriptor, output + offset, output_length - offset);
        if (count > 0) {
            offset += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        close(descriptor);
        return -1;
    }
    return close(descriptor) == 0 ? 0 : -1;
}
#endif
