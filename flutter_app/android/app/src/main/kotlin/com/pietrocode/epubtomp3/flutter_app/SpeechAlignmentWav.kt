package com.pietrocode.epubtomp3.flutter_app

import java.io.File
import java.io.RandomAccessFile

internal data class SpeechRangeStart(val location: Int, val end: Int, val frame: Int)

/** Preserve actual Android range-start frames in the WAV contract Rust already
 * validates. Interval ends use the next measured boundary or actual PCM end;
 * engines without measured ranges keep producing ordinary WAVs. */
internal object SpeechAlignmentWav {
    fun attach(file: File, text: String, ranges: List<SpeechRangeStart>): Boolean {
        if (ranges.isEmpty()) return false
        return RandomAccessFile(file, "rw").use { wav ->
            if (wav.length() < 44 || wav.readInt() != 0x52494646) return@use false
            wav.skipBytes(4)
            if (wav.readInt() != 0x57415645) return@use false
            var rate = 0L
            var blockAlign = 0
            var frames = 0L
            while (wav.filePointer + 8 <= wav.length()) {
                val id = wav.readInt()
                val size = Integer.reverseBytes(wav.readInt()).toLong() and 0xffffffffL
                val start = wav.filePointer
                if (size > wav.length() - start) return@use false
                if (id == 0x666d7420 && size >= 16) {
                    wav.skipBytes(4)
                    rate = Integer.reverseBytes(wav.readInt()).toLong() and 0xffffffffL
                    wav.skipBytes(4)
                    blockAlign = java.lang.Short.reverseBytes(wav.readShort()).toInt() and 0xffff
                }
                if (id == 0x64617461 && blockAlign > 0) frames = size / blockAlign
                wav.seek(start + size + (size and 1))
            }
            if (rate <= 0 || frames <= 0 || wav.length() + 1024 * 1024 > 0xffffffffL) return@use false
            fun boundary(offset: Int): Boolean = offset in 0..text.length &&
                (offset == text.length || !Character.isLowSurrogate(text[offset]))
            if (ranges.any { !boundary(it.location) || !boundary(it.end) ||
                    it.end <= it.location || it.frame < 0 || it.frame >= frames } ||
                ranges.zipWithNext().any { (a, b) -> a.end > b.location || a.frame >= b.frame }) return@use false
            val words = ranges.mapIndexed { index, word ->
                val endFrame = ranges.getOrNull(index + 1)?.frame?.toLong() ?: frames
                "{\"location\":${word.location},\"length\":${word.end - word.location},\"start\":${word.frame.toDouble() / rate},\"end\":${endFrame.toDouble() / rate}}"
            }.joinToString(",")
            val json = "{\"version\":1,\"text\":${quote(text)},\"words\":[$words]}".toByteArray(Charsets.UTF_8)
            if (json.size > 1024 * 1024) return@use false
            wav.seek(wav.length())
            wav.writeBytes("spch")
            wav.writeInt(Integer.reverseBytes(json.size))
            wav.write(json)
            if (json.size % 2 != 0) wav.write(0)
            val size = wav.length() - 8
            wav.seek(4)
            wav.writeInt(Integer.reverseBytes(size.toInt()))
            true
        }
    }

    private fun quote(value: String): String = buildString {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 32) append("\\u%04x".format(character.code)) else append(character)
            }
        }
        append('"')
    }
}
