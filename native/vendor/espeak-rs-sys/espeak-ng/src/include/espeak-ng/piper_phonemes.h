/* Local compatibility bridge for Piper's clause-terminator-aware API.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef PIPER_PHONEMES_H
#define PIPER_PHONEMES_H

#include <espeak-ng/speak_lib.h>

#ifdef __cplusplus
extern "C" {
#endif

ESPEAK_API const char *espeak_TextToPhonemesWithTerminator(
    const void **textptr, int textmode, int phonememode, int *terminator);

#ifdef __cplusplus
}
#endif
#endif
