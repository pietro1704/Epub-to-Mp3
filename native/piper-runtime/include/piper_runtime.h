#ifndef PIPER_RUNTIME_H
#define PIPER_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t runtime_loaded;
    uint8_t model_available;
    uint8_t abi_compatible;
    uint8_t engine_ready;
} piper_runtime_status_t;

piper_runtime_status_t piper_runtime_status(void);
int32_t piper_runtime_register_core(void);
int32_t piper_runtime_init(const char *model, const char *config, char *error, uint32_t error_len);
int32_t piper_synthesize(const char *text, const char *output, char *error, uint32_t error_len);
void piper_runtime_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
