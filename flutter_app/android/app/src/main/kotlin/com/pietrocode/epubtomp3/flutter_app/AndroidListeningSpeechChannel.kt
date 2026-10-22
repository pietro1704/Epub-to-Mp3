package com.pietrocode.epubtomp3.flutter_app

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener

import android.util.Log

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

internal class AndroidListeningSpeechChannel(private val activity: MainActivity) {
    private val methodChannels = mutableListOf<MethodChannel>()
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false
    private var closed = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val replies = ChannelReplies()

    private fun ensureTextToSpeech(): Boolean {
        if (closed) return false
        if (textToSpeechReady) return true
        if (textToSpeech == null) {
            val preferredEngine = if (activity.packageManager.getInstalledPackages(0)
                    .any { it.packageName == "com.google.android.tts" }) {
                "com.google.android.tts"
            } else {
                null
            }
            textToSpeech = if (preferredEngine != null) {
                TextToSpeech(activity, { status ->
                    textToSpeechReady = !closed && status == TextToSpeech.SUCCESS
                    Log.i("AndroidTts", "engine=com.google.android.tts init=$status ready=$textToSpeechReady")
                    textToSpeech?.voices?.map { it.locale.toLanguageTag() }?.distinct()?.let {
                        Log.i("AndroidTts", "available locales=${it.joinToString(",")}")
                    }
                    if (textToSpeechReady) textToSpeech?.language = Locale.US
                }, preferredEngine)
            } else {
                TextToSpeech(activity) { status ->
                    textToSpeechReady = !closed && status == TextToSpeech.SUCCESS
                    Log.i("AndroidTts", "engine=default init=$status ready=$textToSpeechReady")
                    if (textToSpeechReady) textToSpeech?.language = Locale.US
                }
            }
        }
        return textToSpeechReady
    }

    private fun setSpeechLocale(tag: String): Boolean {
        val engine = textToSpeech ?: return false
        val requested = Locale.forLanguageTag(tag)
        val candidates = when (requested.language) {
            "en" -> listOf(requested, Locale.US, Locale.UK)
            "pt" -> listOf(requested, Locale("pt", "PT"))
            "es" -> listOf(requested, Locale("es", "ES"))
            "fr" -> listOf(requested, Locale.FRANCE)
            else -> listOf(requested)
        }
        for (locale in candidates.distinct()) {
            val availability = engine.isLanguageAvailable(locale)
            val selected = engine.setLanguage(locale)
            Log.i("AndroidTts", "locale candidate=${locale.toLanguageTag()} availability=$availability selected=$selected")
            if (availability >= TextToSpeech.LANG_AVAILABLE &&
                selected != TextToSpeech.LANG_MISSING_DATA &&
                selected != TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                Log.i("AndroidTts", "selected locale=${locale.toLanguageTag()}")
                return true
            }
        }
        Log.e("AndroidTts", "requested locale unavailable=$tag")
        return false
    }

    fun configure(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_to_mp3/android_tts")
            .also { methodChannels.add(it) }.setMethodCallHandler { call, originalResult ->
                val result = replies.track(originalResult)
                when (call.method) {
                    "isAvailable" -> result.success(ensureTextToSpeech())
                    "listVoices" -> result.success(textToSpeech?.voices?.map {
                        mapOf("name" to it.name, "locale" to it.locale.toLanguageTag())
                    } ?: emptyList<Map<String, String>>())
                    "speak" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val locale = call.argument<String>("locale") ?: "pt-BR"
                        if (text.isBlank() || !ensureTextToSpeech()) {
                            result.error("TTS_UNAVAILABLE", "Android TextToSpeech is unavailable", null)
                        } else {
                            if (!setSpeechLocale(locale)) {
                                result.error("TTS_LOCALE_UNAVAILABLE", "Requested speech locale is unavailable", locale)
                                return@setMethodCallHandler
                            }
                            val status = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "epub-${System.nanoTime()}")
                                ?: TextToSpeech.ERROR
                            if (status == TextToSpeech.SUCCESS) result.success(null)
                            else result.error("TTS_SPEAK_FAILED", "TextToSpeech rejected the text", null)
                        }
                    }
                    "synthesizeToFile" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val locale = call.argument<String>("locale") ?: "pt-BR"
                        val path = call.argument<String>("path").orEmpty()
                        if (text.isBlank() || path.isBlank() || !ensureTextToSpeech()) {
                            result.error("TTS_UNAVAILABLE", "Android TextToSpeech is unavailable", null)
                        } else if (!setSpeechLocale(locale)) {
                            result.error("TTS_LOCALE_UNAVAILABLE", "Requested speech locale is unavailable", locale)
                        } else {
                            val utteranceId = "file-${System.nanoTime()}"
                            textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                                override fun onStart(id: String?) {
                                    Log.i("AndroidTts", "synthesize start id=$id path=$path")
                                }
                                override fun onError(id: String?) {
                                    Log.e("AndroidTts", "synthesize error id=$id path=$path")
                                    if (id == utteranceId) mainHandler.post {
                                        result.error("TTS_SYNTHESIS_FAILED", "TextToSpeech failed to write audio", null)
                                    }
                                }
                                override fun onDone(id: String?) {
                                    Log.i("AndroidTts", "synthesize done id=$id exists=${File(path).exists()} bytes=${File(path).length()}")
                                    if (id == utteranceId) mainHandler.post { result.success(path) }
                                }
                            })
                            val status = textToSpeech?.synthesizeToFile(text, Bundle(), File(path), utteranceId)
                                ?: TextToSpeech.ERROR
                            Log.i("AndroidTts", "synthesize requested status=$status id=$utteranceId path=$path chars=${text.length}")
                            if (status != TextToSpeech.SUCCESS) {
                                result.error("TTS_SYNTHESIS_FAILED", "TextToSpeech rejected the text", null)
                            }
                        }
                    }
                    "speakQueued" -> {
                        val texts = call.argument<List<String>>("texts").orEmpty()
                        val locale = call.argument<String>("locale") ?: "pt-BR"
                        if (texts.isEmpty() || !ensureTextToSpeech()) {
                            result.error("TTS_UNAVAILABLE", "Android TextToSpeech is unavailable", null)
                        } else {
                            if (!setSpeechLocale(locale)) {
                                result.error("TTS_LOCALE_UNAVAILABLE", "Requested speech locale is unavailable", locale)
                                return@setMethodCallHandler
                            }
                            Log.i("AndroidTts", "queueing chunks=${texts.size} locale=$locale")
                            texts.forEachIndexed { index, text ->
                                textToSpeech?.speak(
                                    text,
                                    if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                                    null,
                                    "epub-${System.nanoTime()}-$index"
                                )
                            }
                            result.success(null)
                        }
                    }
                    "pause", "stop" -> { textToSpeech?.stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            }

    }

    fun close() {
        closed = true
        methodChannels.forEach { it.setMethodCallHandler(null) }
        methodChannels.clear()
        replies.close()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        textToSpeechReady = false
    }
}
