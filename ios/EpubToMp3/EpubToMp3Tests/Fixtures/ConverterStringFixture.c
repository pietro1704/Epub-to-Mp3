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
char *converter_tts_models_json(void) { return owned("[]"); }
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
char *converter_session_convert_json(const void *session, const char *output, int32_t first, int32_t last) {
    (void)session; (void)output; (void)first; (void)last;
    if (mode == 2) return NULL;
    return owned(mode == 1 ? "\xFF\xFE" : "{\"manifest\":{\"jobId\":\"fixture-job\"}}");
}
