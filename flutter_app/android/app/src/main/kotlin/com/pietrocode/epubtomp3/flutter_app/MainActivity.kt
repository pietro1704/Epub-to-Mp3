package com.pietrocode.epubtomp3.flutter_app

import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.speech.tts.TextToSpeech
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
import java.io.FileOutputStream
import java.io.InputStream
import java.util.Locale
import java.util.concurrent.Executors


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
        private const val PIPER_RUNTIME_LIBRARY = "piper_runtime"

        private var converterLibraryLoaded = false
        private var piperLibraryLoaded = false

        init {
            // Native libraries are loaded lazily before the first conversion.
        }

        private fun converterLibraryAvailable(): Boolean {
            return try {
                if (!converterLibraryLoaded) {
                    System.loadLibrary(CONVERTER_LIBRARY)
                    converterLibraryLoaded = true
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !piperLibraryLoaded) {
                    System.loadLibrary(PIPER_RUNTIME_LIBRARY)
                    piperLibraryLoaded = true
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
    private var documentEvents: EventChannel.EventSink? = null
    private var deepLinkEvents: EventChannel.EventSink? = null
    private val pendingDeepLinks = mutableListOf<String>()


    private fun embeddedConverterStatus(): Map<String, Boolean> = try {
        converterLibraryAvailable()
        val model = ensureBundledPiperModel()
        System.setProperty("PIPER_MODEL", model)
        val modelAvailable = File(model).isFile && File("$model.json").isFile
        mapOf(
            "runtimeLoaded" to converterLibraryLoaded,
            "modelAvailable" to modelAvailable,
            "abiCompatible" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || piperLibraryLoaded),
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

    private fun ensureBundledPiperModel(): String {
        val target = File(filesDir, "piper/pt_BR-faber-medium.onnx")
        val config = File(filesDir, "piper/pt_BR-faber-medium.onnx.json")
        if (!target.isFile || !config.isFile) {
            target.parentFile?.mkdirs()
            assets.open("piper/pt_BR-faber-medium.onnx").use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
            assets.open("piper/pt_BR-faber-medium.onnx.json").use { input ->
                FileOutputStream(config).use { output -> input.copyTo(output) }
            }
        }
        return target.absolutePath
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
                                    ensureBundledPiperModel()
                                    System.setProperty("PIPER_MODEL", ensureBundledPiperModel())
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
                                    val model = ensureBundledPiperModel()
                                    System.setProperty("PIPER_MODEL", model)
                                    Log.i(embeddedLogTag, "convert invoking JNI libraryLoaded=$converterLibraryLoaded model=$model")
                                    val native = nativeConvert(inputPath, outputPath)
                                    if (native == null) {
                                        val error = nativeLastError()
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
    private external fun nativeConvert(inputPath: String, outputPath: String): String?
    private external fun nativeTtsModels(): String?
    private external fun nativeTtsDefaultEngine(language: String, platform: String, androidApi: Int): String?
    private external fun nativeTtsModelInstall(modelId: String, url: String, sha256: String, root: String): String?
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

        val document = copyIntoPrivateStorage(uri, incoming.type) ?: return
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
        if (!isTrustedContentUri(uri)) return null
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
        if (extension == null) {
            extension = detectDocumentExtension(uri) ?: return null
        }
        val safeBase = sourceName.substringBeforeLast('.', sourceName)
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .trim('_')
            .ifEmpty { "shared_document" }
        val sourceKey = Integer.toHexString(uri.toString().hashCode())
        val displayName = if (lowerName.endsWith(extension)) sourceName else "$safeBase$extension"
        val target = File(File(filesDir, DOCUMENT_DIR), "${safeBase}_$sourceKey$extension")
        target.parentFile?.mkdirs()
        return try {
            openTrustedInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath to displayName
        } catch (_: Exception) {
            null
        }
    }

    /** Infer common book formats when Android omits the filename extension/MIME. */
    private fun detectDocumentExtension(uri: Uri): String? {
        if (!isTrustedContentUri(uri)) return null
        return try {
            val header = openTrustedInputStream(uri)?.use { it.readNBytes(8) } ?: return null
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
        if (!isTrustedContentUri(uri)) return null
        val cursor: Cursor = contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
        ) ?: return null
        return cursor.use { if (it.moveToFirst()) it.getString(0) else null }
    }

    private fun isTrustedContentUri(uri: Uri): Boolean {
        if (uri.scheme != "content" || uri.authority.isNullOrBlank()) return false

        // A caller controls the content URI. Normalize its path before resolving it so
        // a provider cannot make this activity read the app's private /data storage.
        val normalizedPath = try {
            File(uri.path ?: return false).canonicalPath
        } catch (_: Exception) {
            return false
        }
        return !normalizedPath.startsWith("/data/")
    }

    private fun openTrustedInputStream(uri: Uri): InputStream? {
        if (uri.scheme != "content" || uri.authority.isNullOrBlank()) return null
        return try {
            val normalizedPath = File(uri.path ?: return null).canonicalPath
            if (normalizedPath.startsWith("/data/")) return null
            contentResolver.openInputStream(uri)
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
