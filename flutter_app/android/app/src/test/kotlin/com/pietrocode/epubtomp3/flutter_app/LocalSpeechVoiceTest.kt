package com.pietrocode.epubtomp3.flutter_app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LocalSpeechVoiceTest {
    @Test fun choosesInstalledExactLocaleOnly() {
        val voices = listOf(
            LocalSpeechVoice("network", "pt-BR", true),
            LocalSpeechVoice("portugal", "pt-PT", false),
            LocalSpeechVoice("brazil", "pt-BR", false),
        )
        assertEquals("brazil", selectLocalSpeechVoice(voices, "pt_BR"))
        assertNull(selectLocalSpeechVoice(voices.take(2), "pt-BR"))
    }

    @Test fun selectionIsStableAndNeverDownloadsVoice() {
        val voices = listOf(LocalSpeechVoice("z", "en-US", false), LocalSpeechVoice("a", "en-US", false))
        assertEquals("a", selectLocalSpeechVoice(voices, "en-US"))
        assertEquals("a", selectLocalSpeechVoice(voices.reversed(), "en-US"))
        assertNull(selectLocalSpeechVoice(emptyList(), "pt-BR"))
        assertNull(selectLocalSpeechVoice(listOf(LocalSpeechVoice("missing", "pt-BR", false, installed = false)), "pt-BR"))
    }

    @Test fun prefersLowerAdvertisedLatencyBeforeVoiceName() {
        val voices = listOf(LocalSpeechVoice("a", "pt-BR", false, latency = 500), LocalSpeechVoice("z", "pt-BR", false, latency = 100))
        assertEquals("z", selectLocalSpeechVoice(voices, "pt-BR"))
    }

    @Test fun bareLanguagesPreferDefaultRegionButKeepSameLanguageFallback() {
        val voices = listOf(LocalSpeechVoice("portugal", "pt-PT", false, latency = 100), LocalSpeechVoice("brazil", "pt-BR", false, latency = 500))
        assertEquals("brazil", selectLocalSpeechVoice(voices, "pt"))
        assertEquals("portugal", selectLocalSpeechVoice(voices.take(1), "pt"))
        assertNull(selectLocalSpeechVoice(voices.take(1), "pt-BR"))
        assertNull(selectLocalSpeechVoice(voices, "en"))
    }
}
