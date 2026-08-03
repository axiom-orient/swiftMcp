#ifndef MCP_PLATFORM_CRYPTO_H
#define MCP_PLATFORM_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int mcp_sha256(const uint8_t *input, size_t input_length, uint8_t output[32]);
int mcp_secure_random(uint8_t *output, size_t output_length);

#ifdef __cplusplus
}
#endif

#endif
