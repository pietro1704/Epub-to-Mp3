package com.pietrocode.epubtomp3.flutter_app

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals

class SpeechAlignmentWavTest {
    private fun wav(): java.io.File {
        val file = java.io.File.createTempFile("speech-alignment-", ".wav")
        file.deleteOnExit()
        val bytes = ByteBuffer.allocate(44 + 32000).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("RIFF".toByteArray()).putInt(bytes.capacity() - 8).put("WAVEfmt ".toByteArray())
        bytes.putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16)
        bytes.put("data".toByteArray()).putInt(32000)
        file.writeBytes(bytes.array())
        return file
    }

    @Test fun measuredFramesTravelWithTheOriginalPcm() {
        val file = wav()
        val original = file.readBytes()
        assertTrue(SpeechAlignmentWav.attach(file, "Ação 🐧", listOf(
            SpeechRangeStart(0, 4, 0), SpeechRangeStart(5, 7, 8000))))
        val bytes = file.readBytes()
        assertTrue(bytes.copyOfRange(8, original.size).contentEquals(original.copyOfRange(8, original.size)))
        val metadata = String(bytes.copyOfRange(original.size + 8, bytes.size), Charsets.UTF_8)
        assertTrue(metadata.contains("\"start\":0.5,\"end\":1.0"))
        assertTrue(metadata.contains("Ação 🐧"))
        assertEquals(bytes.size - 8, ByteBuffer.wrap(bytes, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int)
        file.delete()
    }

    @Test fun missingOrInvalidMarkersNeverFabricateAlignment() {
        val file = wav()
        val original = file.readBytes()
        assertFalse(SpeechAlignmentWav.attach(file, "🐧", emptyList()))
        assertFalse(SpeechAlignmentWav.attach(file, "🐧", listOf(SpeechRangeStart(0, 1, 0))))
        assertFalse(SpeechAlignmentWav.attach(file, "Word", listOf(SpeechRangeStart(0, 4, 32000))))
        assertTrue(original.contentEquals(file.readBytes()))
        file.delete()
    }
}
