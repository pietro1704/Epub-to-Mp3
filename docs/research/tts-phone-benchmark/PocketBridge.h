#include <stdint.h>
void *ptt_create(const char *, const char *, const char *, const char *, float, int, int);
void ptt_destroy(void *);
void *ptt_stream_start(void *, const char *, const char *);
int ptt_stream_read(void *, float **, int *);
void ptt_stream_end(void *);
void ptt_free_audio(float *);
