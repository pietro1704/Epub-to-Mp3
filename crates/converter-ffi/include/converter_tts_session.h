#ifndef CONVERTER_TTS_SESSION_H
#define CONVERTER_TTS_SESSION_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Owned UTF-8 JSON; release with converter_string_free. Catalog presence does
 * not assert installation, runtime availability or inference readiness. */
char *converter_tts_catalog_json_v2(void);
/* Owned v3 snapshot with offline installed-artifact inspection. Runtime
 * readiness remains not_inspected until typed probe evidence is available. */
char *converter_tts_catalog_json_v3(const char *language,
                                    const char *platform,
                                    uint32_t android_api,
                                    const char *architecture,
                                    const char *os_version,
                                    const char *model_root);
void converter_string_free(char *value);
/* Existing conversion entry points accept contract_version=2 and captured
 * tts_preferences. Legacy selections are translated at this binding seam. */
bool converter_conversion_options_validate_json_v2(const char *options_json);
typedef struct ConverterJobControl ConverterJobControl;
/* Positions use normalized Unicode scalar offsets. Feedback is audio seconds
 * before playback-rate adjustment; source chapters use the Rust catalog index. */
bool converter_job_control_set_listening_position_json_v2(const ConverterJobControl *control, const char *position_json);
bool converter_job_control_playback_feedback_json_v2(const ConverterJobControl *control, const char *feedback_json);
bool converter_job_control_observe_generation_v2(const ConverterJobControl *control, uint64_t generation, double seconds, uintptr_t chars);
uint64_t converter_job_control_listening_generation_v2(const ConverterJobControl *control);
#ifdef __cplusplus
}
#endif
#endif
