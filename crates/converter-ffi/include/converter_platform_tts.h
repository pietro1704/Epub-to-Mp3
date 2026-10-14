#ifndef CONVERTER_PLATFORM_TTS_H
#define CONVERTER_PLATFORM_TTS_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ConverterSession ConverterSession;
typedef bool (*ConverterPlatformCancelled)(const void *context);
/* Write mono PCM16 WAV to output_wav. Return only when all work has stopped.
 * Check cancellation while waiting. Never play speech directly, download voices,
 * or retain the borrowed cancellation callback/context beyond this call.
 * error_buffer is writable for error_length bytes, including its terminating NUL.
 * The Rust worker owns chunking, MP3 encoding, artifacts and provider selection. */
typedef bool (*ConverterPlatformTtsCallback)(
    const char *text, const char *language, const char *output_wav,
    ConverterPlatformCancelled cancelled, const void *cancel_context,
    char *error_buffer, uint32_t error_length, void *context);
/* Called on background workers; adapters serialize shared speech resources.
 * Configure with no conversion active; context remains alive through conversion.
 * NULL callback removes the adapter. An unconfigured session stays Edge-only. */
bool converter_session_set_platform_tts_v1(
    ConverterSession *session, ConverterPlatformTtsCallback callback, void *context);
#ifdef __cplusplus
}
#endif
#endif
