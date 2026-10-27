/* Preserve the terminator already computed by TranslateClause.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <espeak-ng/piper_phonemes.h>
#include "translate.h"

ESPEAK_API const char *espeak_TextToPhonemesWithTerminator(
    const void **textptr, int textmode, int phonememode, int *terminator)
{
    const char *phonemes = espeak_TextToPhonemes(textptr, textmode, phonememode);
    if (terminator != NULL)
        *terminator = phonemes != NULL && translator != NULL
            ? translator->clause_terminator : 0;
    return phonemes;
}
