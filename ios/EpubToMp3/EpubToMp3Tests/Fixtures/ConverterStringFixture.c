#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// This test-bundle ABI fixture is loaded explicitly through its own bundle URL.
// Normal adapter discovery continues to use the real embedded Rust library.
static int mode;
static int closed_sessions;
static int freed_strings;
static int invalid_frees;
static char *allocations[32];

static char *owned(const char *value) {
    char *copy = strdup(value);
    for (int i = 0; i < 32; i++) {
        if (!allocations[i]) { allocations[i] = copy; return copy; }
    }
    free(copy);
    return NULL;
}

void converter_fixture_reset(int next_mode) {
    for (int i = 0; i < 32; i++) {
        free(allocations[i]);
        allocations[i] = NULL;
    }
    mode = next_mode;
    closed_sessions = 0;
    freed_strings = 0;
    invalid_frees = 0;
}
int converter_fixture_live_strings(void) {
    int live = 0;
    for (int i = 0; i < 32; i++) if (allocations[i]) live++;
    return live;
}
int converter_fixture_freed_strings(void) { return freed_strings; }
int converter_fixture_invalid_frees(void) { return invalid_frees; }
int converter_fixture_closed_sessions(void) { return closed_sessions; }

void *converter_session_open(const char *path) {
    (void)path;
    return mode == 3 || mode == 4 ? NULL : (void *)(uintptr_t)1;
}
void converter_session_free(void *session) {
    if (session == (void *)(uintptr_t)1) closed_sessions++;
}
char *converter_session_metadata_json(const void *session) {
    (void)session;
    if (mode == 2) return NULL;
    return owned(mode == 1 ? "\xFF\xFE" : "{\"book_id\":\"fixture-book\"}");
}
void converter_string_free(char *value) {
    for (int i = 0; i < 32; i++) {
        if (allocations[i] == value && value) {
            allocations[i] = NULL;
            freed_strings++;
            free(value);
            return;
        }
    }
    invalid_frees++;
}
char *converter_last_error(void) {
    return owned(mode == 3 ? "\xFF\xFE" : "fixture failed");
}
char *converter_tts_default_engine(const char *language, const char *platform, uint32_t api) {
    (void)language; (void)platform; (void)api;
    return owned("piper");
}

typedef bool (*PlatformCancelled)(const void *);
typedef bool (*PlatformSynthesis)(const char *, const char *, const char *,
                                 PlatformCancelled, const void *, char *, uint32_t, void *);
bool converter_session_set_platform_tts_v1(void *session, PlatformSynthesis callback, void *context) {
    return session != NULL && callback != NULL && context != NULL;
}
bool converter_conversion_options_validate_json_v1(const char *options) { return options != NULL; }
bool converter_conversion_options_validate_json_v2(const char *options) { return options != NULL; }
void *converter_job_control_create(void) { return malloc(1); }
void converter_job_control_free(void *control) { free(control); }
void converter_job_control_cancel(const void *control) { (void)control; }
bool converter_job_control_prioritize(const void *control, size_t chapter) { (void)chapter; return control != NULL; }
void converter_job_control_set_playback_window(const void *control, size_t chapter, size_t ahead) {
    (void)control; (void)chapter; (void)ahead;
}
bool converter_job_control_chapter_is_in_playback_window(const void *control, size_t chapter) {
    (void)chapter; return control != NULL;
}
bool converter_job_control_chapter_is_preempted(const void *control, size_t chapter) {
    (void)control; (void)chapter; return false;
}
char *converter_session_convert_streaming_job_options_json_v1(
    const void *session, const char *output, const char *job, const char *options,
    int32_t first, int32_t last, void *progress, void *chapter, void *chunk, void *context,
    const void *control
) {
    (void)job; (void)options; (void)progress; (void)chapter; (void)chunk; (void)context; (void)control;
    (void)session; (void)output; (void)first; (void)last;
    if (mode == 2) return NULL;
    return owned(mode == 1 ? "\xFF\xFE" : "{\"manifest\":{\"jobId\":\"fixture-job\"}}");
}
