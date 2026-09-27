#ifndef TG_SMC_H
#define TG_SMC_H
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint32_t size; uint32_t type; uint8_t attributes; } TGKeyInfo;
uint32_t tg_smc_open(void);
void tg_smc_close(uint32_t connection);
bool tg_smc_key_at(uint32_t connection, uint32_t index, uint32_t *key);
bool tg_smc_info(uint32_t connection, uint32_t key, TGKeyInfo *info);
bool tg_smc_read(uint32_t connection, uint32_t key, TGKeyInfo info, double *value);
bool tg_smc_decode(uint32_t type, const uint8_t *bytes, uint32_t size, double *value);
#endif
