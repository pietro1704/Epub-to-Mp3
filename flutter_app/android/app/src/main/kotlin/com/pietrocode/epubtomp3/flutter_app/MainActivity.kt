package com.pietrocode.epubtomp3.flutter_app

import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.Environment
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.provider.OpenableColumns

import android.util.Log
import androidx.work.Data
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException



/**
 * Hosts Flutter and Android document ingestion.
 * Incoming content URIs are copied into app-private storage before they are
 * exposed to Dart, because a content URI is not a durable filesystem path.
 */
class MainActivity : AudioServiceActivity() {

    private val embeddedLogTag = "EmbeddedConverter"
    private val converterExecutor = Executors.newSingleThreadExecutor()
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false


    companion object {
        private const val CHANNEL = "epub_to_mp3/embedded_rust"
        private const val DOCUMENT_CHANNEL = "epub_to_mp3/incoming_documents"
        private const val DOCUMENT_EVENTS_CHANNEL = "epub_to_mp3/incoming_documents/events"
        private const val DEEP_LINK_EVENTS_CHANNEL = "epub_to_mp3/deep_links"
        private const val DOCUMENT_QUEUE = "incoming_documents.v1"
        private const val DOCUMENT_DIR = "incoming_documents"
        private const val EMBEDDED_CHANNEL = "epub_to_mp3/embedded_converter"
        private const val EMBEDDED_UNAVAILABLE = "EMBEDDED_CONVERTER_UNAVAILABLE"
        private const val CONVERTER_LIBRARY = "converter_ffi"
        private const val DOCUMENT_PICKER_REQUEST = 4107
        private const val MAX_IMPORT_BYTES = 512L * 1024L * 1024L
        private var converterLibraryLoaded = false

        init {
            // Native libraries are loaded lazily before the first conversion.
        }

        private fun converterLibraryAvailable(): Boolean {
            // The packaged converter is Edge-only on legacy Android devices.
            // Piper remains a separately gated local runtime and is never
            // loaded here on API 28.
            return try {
                if (!converterLibraryLoaded) {
                    System.loadLibrary(CONVERTER_LIBRARY)
                    converterLibraryLoaded = true
                }
                converterLibraryLoaded
            } catch (_: UnsatisfiedLinkError) {
                false
            }
        }

        private fun registerEmbeddedPiper() {
            // The native converter resolves the Piper runtime directly from
            // its linked library; no JNI symbol is required for registration.
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val incomingDocumentUriPolicy by lazy {
        IncomingDocumentUriPolicy(listOf(Environment.getExternalStorageDirectory()))
    }
    private var documentEvents: EventChannel.EventSink? = null
    private var deepLinkEvents: EventChannel.EventSink? = null
    private var pendingDocumentPickerResult: MethodChannel.Result? = null
    private val pendingDeepLinks = mutableListOf<String>()

    private fun embeddedConverterStatus(): Map<String, Boolean> = try {
        converterLibraryAvailable()
        val modelAvailable = installedLocalModel() != null
        mapOf(
            "runtimeLoaded" to converterLibraryLoaded,
            "modelAvailable" to modelAvailable,
            "abiCompatible" to converterLibraryLoaded,
            // Edge is the online default and does not require a local model.
            "engineReady" to converterLibraryLoaded,
        )
    } catch (_: Throwable) {
        mapOf(
            "runtimeLoaded" to false,
            "modelAvailable" to false,
            "abiCompatible" to false,
            "engineReady" to false,
        )
    }

    private fun installedLocalModel(): String? {
        val root = File(filesDir, "tts-models")
        return root.listFiles()
            ?.asSequence()
            ?.flatMap { directory ->
                sequenceOf(
                    File(directory, "model.onnx"),
                    File(directory, "model.bin"),
                )
            }
            ?.firstOrNull { it.isFile }
            ?.absolutePath
    }

    private fun ensureTextToSpeech(): Boolean {
        if (textToSpeechReady) return true
        if (textToSpeech == null) {
            val preferredEngine = if (packageManager.getInstalledPackages(0)
                    .any { it.packageName == "com.google.android.tts" }) {
                "com.google.android.tts"
            } else {
                null
            }
            textToSpeech = if (preferredEngine != null) {
                TextToSpeech(this, { status ->
                    textToSpeechReady = status == TextToSpeech.SUCCESS
                    Log.i("AndroidTts", "engine=com.google.android.tts init=$status ready=$textToSpeechReady")
                    textToSpeech?.voices?.map { it.locale.toLanguageTag() }?.distinct()?.let {
                        Log.i("AndroidTts", "available locales=${it.joinToString(",")}")
                    }
                    if (textToSpeechReady) textToSpeech?.language = Locale.US
                }, preferredEngine)
            } else {
                TextToSpeech(this) { status ->
                    textToSpeechReady = status == TextToSpeech.SUCCESS
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)

    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    @Deprecated("Deprecated in Android API Activity, retained for API 28 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DOCUMENT_PICKER_REQUEST) return
        val callback = pendingDocumentPickerResult ?: return
        pendingDocumentPickerResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }
        val uri = data.data!!
        val document = copyIntoPrivateStorage(uri, contentResolver.getType(uri))
        if (document == null) {
            callback.error("DOCUMENT_IMPORT_FAILED", "Could not copy the selected document", null)
        } else {
            callback.success(document.first)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // AudioServiceActivity supplies audio_service's shared engine. Register
        // only this activity's channels on that engine; do not create or cache
        // another engine here.
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_to_mp3/android_tts")
            .setMethodCallHandler { call, result ->
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

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_EVENTS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                documentEvents = events
            }

            override fun onCancel(arguments: Any?) {
                documentEvents = null
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEP_LINK_EVENTS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                deepLinkEvents = events
                pendingDeepLinks.forEach { events?.success(it) }
                pendingDeepLinks.clear()
            }

            override fun onCancel(arguments: Any?) {
                deepLinkEvents = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> {
                    Log.i(embeddedLogTag, "native document picker requested")
                    if (pendingDocumentPickerResult != null) {
                        result.error("PICKER_BUSY", "A document picker is already open", null)
                    } else {
                        pendingDocumentPickerResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(
                                    Intent.EXTRA_MIME_TYPES,
                                    arrayOf("application/epub+zip", "application/pdf"),
                                )
                            },
                            DOCUMENT_PICKER_REQUEST,
                        )
                    }
                }
                "getPendingDocuments" -> result.success(readQueue())
                "acknowledgeDocument" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("BAD_ARGS", "path is required", null)
                    } else {
                        acknowledge(path)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }


        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "epub_to_mp3/background_conversion"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueueChapter" -> {
                    val jobId = call.argument<String>("jobId")
                    val text = call.argument<String>("text")
                    val voice = call.argument<String>("voice")
                    val outputPath = call.argument<String>("outputPath")
                    if (jobId.isNullOrBlank() || text.isNullOrBlank() || voice.isNullOrBlank() || outputPath.isNullOrBlank()) {
                        result.error("BAD_ARGS", "jobId, text, voice and outputPath are required", null)
                    } else {
                        val backendUrl = call.argument<String>("backendUrl")?.trim()
                        if (backendUrl.isNullOrBlank()) {
                            result.error("BAD_ARGS", "backendUrl is required", null)
                        } else {
                            val payloadFile = persistBackgroundPayload(jobId, text, voice, outputPath)
                            if (payloadFile == null) {
                                result.error("IO_ERROR", "Could not persist background conversion payload", null)
                                return@setMethodCallHandler
                            }
                            getSharedPreferences("flutter_epub_to_mp3", MODE_PRIVATE)
                                .edit().putString(BackgroundChapterWorker.KEY_BACKEND_URL, backendUrl).apply()
                            val request = OneTimeWorkRequestBuilder<BackgroundChapterWorker>()
                            .setConstraints(
                                Constraints.Builder()
                                    .setRequiresBatteryNotLow(true)
                                    .setRequiresStorageNotLow(true)
                                    .build(),
                            )
                            .setInputData(Data.Builder()
                                .putString(BackgroundChapterWorker.KEY_PAYLOAD, payloadFile.absolutePath)
                                .build())
                            .build()
                            WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                                jobId, ExistingWorkPolicy.KEEP, request,
                            )
                            result.success(true)
                        }
                    }
                }
                "cancel" -> {
                    val jobId = call.argument<String>("jobId")
                    if (jobId.isNullOrBlank()) result.error("BAD_ARGS", "jobId is required", null)
                    else {
                        WorkManager.getInstance(applicationContext).cancelUniqueWork(jobId)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "epub_to_mp3/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "availableBytes" -> result.success(StatFs(filesDir.absolutePath).availableBytes)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EMBEDDED_CHANNEL
        ).setMethodCallHandler { call, result ->
            Log.i(embeddedLogTag, "method ${call.method} received")
            when (call.method) {
                "status" -> {
                    Log.i(embeddedLogTag, "status requested")
                    result.success(embeddedConverterStatus())
                }
                "ttsModels" -> {
                    if (!converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsModels()
                            runOnUiThread {
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "ttsDefaultEngine" -> {
                    if (!converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val language = call.argument<String>("language")
                        val platform = call.argument<String>("platform") ?: "android"
                        val androidApi = call.argument<Int>("androidApi") ?: android.os.Build.VERSION.SDK_INT
                        if (language.isNullOrBlank()) {
                            result.error("BAD_ARGS", "language is required", null)
                        } else {
                            converterExecutor.execute {
                                val value = nativeTtsDefaultEngine(language, platform, androidApi)
                                runOnUiThread {
                                    if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                    else result.success(value)
                                }
                            }
                        }
                    }
                }
                "ttsModelInstall" -> {
                    val modelId = call.argument<String>("modelId")
                    val url = call.argument<String>("url")
                    val sha256 = call.argument<String>("sha256")
                    val root = call.argument<String>("root")
                    if (modelId.isNullOrBlank() || url.isNullOrBlank() || sha256.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId, url, sha256, and root are required", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsModelInstall(modelId, url, sha256, root)
                            runOnUiThread {
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "ttsInstalledReadyEngine" -> {
                    val language = call.argument<String>("language")
                    val platform = call.argument<String>("platform") ?: "android"
                    val androidApi = call.argument<Int>("androidApi") ?: android.os.Build.VERSION.SDK_INT
                    val installedJson = call.argument<String>("installedModelIdsJson") ?: "[]"
                    val readyJson = call.argument<String>("readyModelIdsJson") ?: "[]"
                    if (language.isNullOrBlank()) {
                        result.error("BAD_ARGS", "language is required", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsInstalledReadyEngine(
                                language, platform, androidApi, installedJson, readyJson
                            )
                            runOnUiThread {
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "ttsModelInstallManifest" -> {
                    val modelId = call.argument<String>("modelId")
                    val artifactsJson = call.argument<String>("artifactsJson")
                    val root = call.argument<String>("root")
                    if (modelId.isNullOrBlank() || artifactsJson.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId, artifactsJson, and root are required", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsModelInstallManifest(modelId, artifactsJson, root)
                            runOnUiThread {
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "ttsModelInstallCatalogManifest" -> {
                    val modelId = call.argument<String>("modelId")
                    val root = call.argument<String>("root")
                    Log.i(embeddedLogTag, "ttsModelInstallCatalogManifest model=$modelId root=$root")
                    if (modelId.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId and root are required", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsModelInstallCatalogManifest(modelId, root)
                            runOnUiThread {
                                Log.i(embeddedLogTag, "ttsModelInstallCatalogManifest completed model=$modelId value=${value != null}")
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "piperSynthesize" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val output = call.argument<String>("output").orEmpty()
                    Log.i(embeddedLogTag, "piperSynthesize start output=$output chars=${text.length}")
                    converterExecutor.execute {
                        val isolatedExecutor = Executors.newSingleThreadExecutor()
                        try {
                            val nativeFuture = isolatedExecutor.submit<Pair<Boolean, String?>> {
                                val value = nativePiperSynthesize(text, output)
                                value to if (value) null else nativeLastError()
                            }
                            val (value, error) = nativeFuture.get(120, TimeUnit.SECONDS)
                            Log.i(embeddedLogTag, "piperSynthesize completed success=$value error=$error")
                            runOnUiThread {
                                if (value) result.success(output)
                                else result.error(EMBEDDED_UNAVAILABLE, error ?: "Piper synthesis failed", null)
                            }
                        } catch (error: TimeoutException) {
                            Log.e(embeddedLogTag, "piperSynthesize timed out after 120 seconds")
                            runOnUiThread {
                                result.error("PIPER_SYNTHESIS_TIMEOUT", "Piper synthesis timed out", null)
                            }
                        } catch (error: Throwable) {
                            Log.e(embeddedLogTag, "piperSynthesize failed", error)
                            runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error.message, null) }
                        } finally {
                            isolatedExecutor.shutdownNow()
                        }
                    }
                }
                "ttsModelMetadata" -> {
                    val modelId = call.argument<String>("modelId")
                    val root = call.argument<String>("root")
                    if (modelId.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId and root are required", null)
                    } else {
                        converterExecutor.execute {
                            val value = nativeTtsModelMetadata(modelId, root)
                            runOnUiThread { result.success(value) }
                        }
                    }
                }
                "ttsModelRemove" -> {
                    val modelId = call.argument<String>("modelId")
                    val root = call.argument<String>("root")
                    if (modelId.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId and root are required", null)
                    } else {
                        converterExecutor.execute {
                            val removed = nativeTtsModelRemove(modelId, root)
                            runOnUiThread { result.success(removed) }
                        }
                    }
                }
                "parse" -> {
                    if (!converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val inputPath = call.argument<String>("inputPath")
                        if (inputPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "inputPath is required", null)
                        } else {
                            Log.i(embeddedLogTag, "parse start input=$inputPath")
                            converterExecutor.execute {
                                try {
                                    val native = nativeParse(inputPath)
                                    runOnUiThread {
                                        if (native == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                        else result.success(native)
                                    }
                                } catch (error: Throwable) {
                                    runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error.message, null) }
                                }
                            }
                        }
                    }
                }
                "convert" -> {
                    if (!converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val inputPath = call.argument<String>("inputPath")
                        val outputPath = call.argument<String>("outputPath")
                        if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "inputPath and outputPath are required", null)
                        } else {
                            converterExecutor.execute {
                                try {
                                    Log.i(embeddedLogTag, "convert start input=$inputPath output=$outputPath")
                                    // The native request is Edge-first. A local Piper model is
                                    // optional and must not gate the online default.
                                    Log.i(embeddedLogTag, "convert invoking JNI libraryLoaded=$converterLibraryLoaded engine=edge")
                                    val chapterStart = call.argument<Int>("chapterStart") ?: -1
                                    val chapterEnd = call.argument<Int>("chapterEnd") ?: -1
                                    val isolatedExecutor = Executors.newSingleThreadExecutor()
                                    // converter_last_error is thread-local. Read it on the
                                    // same worker thread immediately after nativeConvert;
                                    // reading it after Future.get would lose the real error.
                                    val nativeFuture = isolatedExecutor.submit<Pair<String?, String?>> {
                                        val value = nativeConvert(inputPath, outputPath, chapterStart, chapterEnd)
                                        value to if (value == null) nativeLastError() else null
                                    }
                                    // A complete EPUB can legitimately take several minutes on
                                    // legacy hardware when Edge processes chapters serially. Keep
                                    // the watchdog finite, but do not abort a valid long-running
                                    // conversion after the old one-chapter timeout.
                                    val (native, nativeError) = try {
                                        nativeFuture.get(900, TimeUnit.SECONDS)
                                    } catch (_: TimeoutException) {
                                        nativeFuture.cancel(true)
                                        Log.e(embeddedLogTag, "embedded conversion timed out after 900 seconds")
                                        runOnUiThread {
                                            result.error(
                                                "EMBEDDED_CONVERSION_TIMEOUT",
                                                "Embedded conversion timed out after 900 seconds",
                                                null
                                            )
                                        }
                                        return@execute
                                    } finally {
                                        isolatedExecutor.shutdownNow()
                                    }
                                    if (native == null) {
                                        val error = nativeError ?: "converter-ffi failed without an error"
                                        Log.e(embeddedLogTag, "convert failed: $error")
                                        runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error, null) }
                                    } else {
                                        Log.i(embeddedLogTag, "convert native returned ${native.length} chars")
                                        runOnUiThread { result.success(native) }
                                    }
                                } catch (error: Throwable) {
                                    Log.e(embeddedLogTag, "native conversion failed", error)
                                    runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error.message, null) }
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }


    }

    private external fun nativeParse(inputPath: String): String?
    private external fun nativeConvert(inputPath: String, outputPath: String, chapterStart: Int, chapterEnd: Int): String?
    private external fun nativeTtsModels(): String?
    private external fun nativeTtsDefaultEngine(language: String, platform: String, androidApi: Int): String?
    private external fun nativeTtsInstalledReadyEngine(language: String, platform: String, androidApi: Int, installedModelIdsJson: String, readyModelIdsJson: String): String?
    private external fun nativeTtsModelInstall(modelId: String, url: String, sha256: String, root: String): String?
    private external fun nativeTtsModelInstallManifest(modelId: String, artifactsJson: String, root: String): String?
    private external fun nativeTtsModelInstallCatalogManifest(modelId: String, root: String): String?
    private external fun nativePiperSynthesize(text: String, output: String): Boolean
    private external fun nativeTtsModelMetadata(modelId: String, root: String): String?
    private external fun nativeTtsModelRemove(modelId: String, root: String): Boolean

    private external fun nativeLastError(): String

    override fun onDestroy() {
        converterExecutor.shutdownNow()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    private fun persistBackgroundPayload(jobId: String, text: String, voice: String, outputPath: String): File? {
        val dir = File(cacheDir, "background_conversion").apply { mkdirs() }
        val target = File(dir, "${jobId.replace(Regex("[^A-Za-z0-9_-]"), "_")}.json")
        val temp = File(dir, "${target.name}.${System.nanoTime()}.tmp")
        return try {
            JSONObject().apply {
                put("text", text)
                put("voice", voice)
                put("outputPath", outputPath)
            }.toString().also { temp.writeText(it, Charsets.UTF_8) }
            if (!temp.renameTo(target)) throw java.io.IOException("Could not atomically publish payload")
            target
        } catch (_: Exception) {
            temp.delete()
            null
        }
    }

    private fun handleIncomingIntent(incoming: Intent?) {
        if (incoming == null) return
        val uri = when (incoming.action) {
            Intent.ACTION_VIEW -> incoming.data
            Intent.ACTION_SEND -> incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                ?: incoming.clipData?.getItemAt(0)?.uri
            else -> null
        } ?: return

        if (uri.scheme.equals("epubtomp3", ignoreCase = true)) {
            forwardDeepLink(uri)
            return
        }

        converterExecutor.execute {
            val document = copyIntoPrivateStorage(uri, incoming.type)
            mainHandler.post {
                if (document == null) {
                    documentEvents?.error("DOCUMENT_IMPORT_FAILED", "Could not validate or copy the incoming document", uri.toString())
                    return@post
                }
                val path = document.first
                val displayName = document.second
                val queue = readQueueObjects()
                if ((0 until queue.length()).none { queue.optJSONObject(it)?.optString("path") == path }) {
                    queue.put(JSONObject().apply {
                        put("path", path)
                        put("displayName", displayName)
                        put("source", uri.toString())
                    })
                    writeQueue(queue)
                }
                documentEvents?.success(mapOf("path" to path, "displayName" to displayName))
            }
        }
    }

    private fun forwardDeepLink(uri: Uri) {
        val value = uri.toString()
        val sink = deepLinkEvents
        if (sink != null) {
            sink.success(value)
        } else {
            pendingDeepLinks.add(value)
        }
    }

    private fun copyIntoPrivateStorage(uri: Uri, mimeType: String?): Pair<String, String>? {
        if (!incomingDocumentUriPolicy.isAllowed(uri)) return null
        val sourceName = queryDisplayName(uri)
            ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "shared_document"
        val lowerName = sourceName.lowercase(Locale.US)
        var extension = when {
            lowerName.endsWith(".pdf") -> ".pdf"
            lowerName.endsWith(".epub") -> ".epub"
            mimeType == "application/pdf" -> ".pdf"
            mimeType == "application/epub+zip" -> ".epub"
            else -> null
        }
        val signatureExtension = detectDocumentExtension(uri) ?: return null
        if (extension != null && extension != signatureExtension) return null
        extension = signatureExtension
        val safeBase = sourceName.substringBeforeLast('.', sourceName)
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .trim('_')
            .ifEmpty { "shared_document" }
        val sourceKey = java.security.MessageDigest.getInstance("SHA-256")
            .digest(uri.toString().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }.take(24)
        val displayName = if (lowerName.endsWith(extension)) sourceName else "$safeBase$extension"
        val target = File(File(filesDir, DOCUMENT_DIR), "${safeBase}_$sourceKey$extension")
        target.parentFile?.mkdirs()
        return try {
            openTrustedInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    var total = 0L
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_IMPORT_BYTES) throw IllegalArgumentException("document exceeds import limit")
                        output.write(buffer, 0, count)
                    }
                }
            } ?: return null
            target.absolutePath to displayName
        } catch (_: Exception) {
            target.delete()
            null
        }
    }

    /** Infer common book formats when Android omits the filename extension/MIME. */
    private fun detectDocumentExtension(uri: Uri): String? {
        if (!incomingDocumentUriPolicy.isAllowed(uri)) return null
        return try {
            val header = openTrustedInputStream(uri)?.use { input ->
                val buffer = ByteArray(8)
                var total = 0
                while (total < buffer.size) {
                    val count = input.read(buffer, total, buffer.size - total)
                    if (count < 0) break
                    total += count
                }
                buffer.copyOf(total)
            } ?: return null
            when {
                header.size >= 4 && header[0] == '%'.code.toByte() &&
                    header[1] == 'P'.code.toByte() && header[2] == 'D'.code.toByte() &&
                    header[3] == 'F'.code.toByte() -> ".pdf"
                header.size >= 2 && header[0] == 'P'.code.toByte() &&
                    header[1] == 'K'.code.toByte() -> ".epub"
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (!incomingDocumentUriPolicy.isAllowed(uri)) return null
        val cursor: Cursor = contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
        ) ?: return null
        return cursor.use { if (it.moveToFirst()) it.getString(0) else null }
    }

    private fun isTrustedContentUri(uri: Uri): Boolean {
        return incomingDocumentUriPolicy.isAllowed(uri)
    }

    private fun openTrustedInputStream(uri: Uri): InputStream? {
        if (!incomingDocumentUriPolicy.isAllowed(uri)) return null
        return try {
            when (uri.scheme?.lowercase()) {
                "content" -> contentResolver.openInputStream(uri)
                "file" -> File(uri.path!!).canonicalFile.inputStream()
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readQueueObjects(): JSONArray = try {
        JSONArray(getPreferences(MODE_PRIVATE).getString(DOCUMENT_QUEUE, "[]"))
    } catch (_: Exception) {
        JSONArray()
    }

    private fun readQueue(): List<Map<String, String>> {
        val result = mutableListOf<Map<String, String>>()
        val queue = readQueueObjects()
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            result.add(mapOf("path" to item.optString("path"), "displayName" to item.optString("displayName")))
        }
        return result
    }

    private fun writeQueue(queue: JSONArray) {
        getPreferences(MODE_PRIVATE).edit().putString(DOCUMENT_QUEUE, queue.toString()).apply()
    }

    private fun acknowledge(path: String) {
        val old = readQueueObjects()
        val next = JSONArray()
        for (i in 0 until old.length()) {
            val item = old.optJSONObject(i) ?: continue
            if (item.optString("path") != path) next.put(item)
        }
        writeQueue(next)
    }
}
