#ifndef CONVERTER_TTS_SESSION_H
#define CONVERTER_TTS_SESSION_H
#include <stdbool.h>
#include <stddef.h>
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
/* Explicit offline model loading; call off the UI thread. No audio/download. */
char *converter_tts_catalog_probe_json_v3(const char *language,
                                          const char *platform,
                                          uint32_t android_api,
                                          const char *architecture,
                                          const char *os_version,
                                          const char *model_root,
                                          const char *espeak_data_directory);
typedef struct ConverterModelInstallOperation ConverterModelInstallOperation;
ConverterModelInstallOperation *converter_tts_model_install_operation_create(
    const char *model_id, const char *model_root, uint64_t available_bytes);
ConverterModelInstallOperation *converter_tts_model_install_operation_recover(
    const char *model_id, const char *model_root, uint64_t available_bytes);
char *converter_tts_model_install_operation_plan_json(
    const ConverterModelInstallOperation *operation);
char *converter_tts_model_install_operation_event_json(
    const ConverterModelInstallOperation *operation);
bool converter_tts_model_install_operation_record_progress(
    const ConverterModelInstallOperation *operation,
    size_t artifact_index,
    uint64_t downloaded_bytes);
bool converter_tts_model_install_operation_accept_download(
    const ConverterModelInstallOperation *operation,
    size_t artifact_index,
    const char *downloaded_path);
char *converter_tts_model_install_operation_publish(
    const ConverterModelInstallOperation *operation);
bool converter_tts_model_install_operation_fail(
    const ConverterModelInstallOperation *operation,
    const char *kind,
    const char *message);
void converter_tts_model_install_operation_cancel(
    const ConverterModelInstallOperation *operation);
void converter_tts_model_install_operation_free(
    ConverterModelInstallOperation *operation);
void converter_string_free(char *value);
/* Existing conversion entry points accept contract_version=2 and captured
 * tts_preferences. Legacy selections are translated at this binding seam. */
bool converter_conversion_options_validate_json_v2(const char *options_json);
typedef struct ConverterJobControl ConverterJobControl;
/* Bounded installed-Piper audition; creates no conversion job or selection. */
bool converter_voice_audition_v1(const char *options_json, const char *text,
    const char *output, const ConverterJobControl *control);
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
