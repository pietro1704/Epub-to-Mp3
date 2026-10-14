package com.pietrocode.epubtomp3.flutter_app

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal data class LocalSpeechVoice(
    val name: String,
    val locale: String,
    val requiresNetwork: Boolean,
    val installed: Boolean = true,
    val latency: Int = 500,
)

/** Never substitute another region or a network voice for an offline request. */
internal fun selectLocalSpeechVoice(voices: List<LocalSpeechVoice>, language: String): String? {
    val requested = Locale.forLanguageTag(language.replace('_', '-')).toLanguageTag()
    val locale = Locale.forLanguageTag(requested)
    val preferred = when (locale.language) { "pt" -> "pt-BR"; "en" -> "en-US"; "es" -> "es-ES"; else -> requested }
    return voices.filter {
        val candidate = Locale.forLanguageTag(it.locale)
        it.installed && !it.requiresNetwork && (if (locale.country.isEmpty()) candidate.language == locale.language else candidate.toLanguageTag() == requested)
    }.sortedWith(compareBy<LocalSpeechVoice> { if (locale.country.isEmpty() && it.locale == preferred) 0 else 1 }
        .thenBy { it.latency }.thenBy { it.name }).firstOrNull()?.name
}

/** A synchronous WAV adapter for Rust workers; Android operations run on the main thread. */
internal class PlatformSpeechProvider(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val initialized = CountDownLatch(1)
    private val initError = AtomicReference<String?>(null)
    private var engine: TextToSpeech? = null
    @Volatile private var closed = false
    private var started = false
    private val requestGate = SpeechRequestGate()

    fun synthesize(text: String, language: String, path: String, cancelled: () -> Boolean, onVoiceSelected: () -> Unit) {
        requestGate.withPermit({ closed || cancelled() }) {
            synthesizeLocked(text, language, path, cancelled, onVoiceSelected)
        }
    }

    private fun synthesizeLocked(text: String, language: String, path: String, cancelled: () -> Boolean, onVoiceSelected: () -> Unit) {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Native speech cannot block the main thread" }
        check(!closed) { "Native speech provider is closed" }
        if (!started) {
            started = true
            handler.post {
                if (closed) { initialized.countDown(); return@post }
                engine = TextToSpeech(context.applicationContext) { status ->
                    if (status != TextToSpeech.SUCCESS) initError.set("Android speech engine initialization failed: $status")
                    initialized.countDown()
                }
            }
        }
        await(initialized, cancelled, 20, "Speech engine initialization")
        initError.get()?.let { throw IllegalStateException(it) }
        check(!closed) { "Native speech provider is closed" }
        require(text.isNotBlank() && text.length <= TextToSpeech.getMaxSpeechInputLength()) { "Native speech chunk exceeds Android's input limit" }
        val finished = CountDownLatch(1)
        val error = AtomicReference<String?>(null)
        val file = File(path)
        file.parentFile?.mkdirs()
        val utterance = "native-${System.nanoTime()}"
        handler.post {
            try {
                check(!closed) { "Native speech provider is closed" }
                val tts = checkNotNull(engine) { "Android speech engine is unavailable" }
                val voices = tts.voices.orEmpty()
                val selected = selectLocalSpeechVoice(voices.map {
                    LocalSpeechVoice(it.name, it.locale.toLanguageTag(), it.isNetworkConnectionRequired,
                        !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED), it.latency)
                }, language) ?: error("No installed offline speech voice for $language")
                check(tts.setVoice(voices.first { it.name == selected }) == TextToSpeech.SUCCESS) { "Could not select offline speech voice" }
                tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) { if (id == utterance) finished.countDown() }
                    @Deprecated("Android legacy callback")
                    override fun onError(id: String?) { fail(id, "Android speech synthesis failed") }
                    override fun onError(id: String?, code: Int) { fail(id, "Android speech synthesis failed: $code") }
                    override fun onStop(id: String?, interrupted: Boolean) { fail(id, "Android speech synthesis stopped") }
                    private fun fail(id: String?, message: String) {
                        if (id == utterance) { error.set(message); finished.countDown() }
                    }
                })
                check(tts.synthesizeToFile(text, Bundle(), file, utterance) == TextToSpeech.SUCCESS) { "Android speech rejected the chunk" }
                onVoiceSelected()
            } catch (failure: Exception) {
                error.set(failure.message ?: "Android speech synthesis failed")
                finished.countDown()
            }
        }
        try {
            await(finished, cancelled, 120, "Speech synthesis")
            error.get()?.let { throw IllegalStateException(it) }
            check(file.isFile && file.length() > 44) { "Android speech produced no WAV audio" }
        } catch (failure: Exception) {
            // Drain the main-thread stop before another worker can acquire this provider.
            val stopped = CountDownLatch(1)
            handler.post { engine?.stop(); engine?.setOnUtteranceProgressListener(null); file.delete(); stopped.countDown() }
            if (!stopped.await(5, TimeUnit.SECONDS)) closed = true
            throw failure
        }
    }

    private fun await(latch: CountDownLatch, cancelled: () -> Boolean, seconds: Long, operation: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (true) {
            check(!closed && !Thread.currentThread().isInterrupted && !cancelled()) { "$operation cancelled" }
            if (latch.await(50, TimeUnit.MILLISECONDS)) return
            check(System.nanoTime() < deadline) { "$operation timed out" }
        }
    }

    fun close() {
        closed = true
        initialized.countDown()
        handler.post { engine?.stop(); engine?.shutdown(); engine = null }
    }
}
