package com.pietrocode.epubtomp3.flutter_app

import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.speech.tts.TextToSpeech
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

/**
 * Hosts Flutter, the embedded Python runtime, and Android document ingestion.
 * Incoming content URIs are copied into app-private storage before they are
 * exposed to Dart, because a content URI is not a durable filesystem path.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "epub_to_mp3/python"
        private const val PY_MODULE = "python_app.src.android_entrypoints"
        private const val DOCUMENT_CHANNEL = "epub_to_mp3/incoming_documents"
        private const val DOCUMENT_EVENTS_CHANNEL = "epub_to_mp3/incoming_documents/events"
        private const val DEEP_LINK_EVENTS_CHANNEL = "epub_to_mp3/deep_links"
        private const val DOCUMENT_QUEUE = "incoming_documents.v1"
        private const val DOCUMENT_DIR = "incoming_documents"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var documentEvents: EventChannel.EventSink? = null
    private var deepLinkEvents: EventChannel.EventSink? = null
    private val pendingDeepLinks = mutableListOf<String>()
    private var offlineTts: TextToSpeech? = null
    private var offlineTtsReady = false

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
        super.configureFlutterEngine(flutterEngine)

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

        offlineTts = TextToSpeech(this) { status ->
            offlineTtsReady = status == TextToSpeech.SUCCESS
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "epub_to_mp3/android_tts"
        ).setMethodCallHandler { call, result ->
            val tts = offlineTts
            when (call.method) {
                "isAvailable" -> result.success(offlineTtsReady && tts != null)
                "listVoices" -> {
                    if (!offlineTtsReady || tts == null) {
                        result.success(emptyList<Map<String, String>>())
                    } else {
                        result.success(tts.voices.map { voice ->
                            mapOf("name" to voice.name, "locale" to voice.locale.toLanguageTag())
                        })
                    }
                }
                "speak" -> {
                    val text = call.argument<String>("text")
                    val localeTag = call.argument<String>("locale")
                    if (!offlineTtsReady || tts == null || text.isNullOrBlank() || localeTag.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        val locale = Locale.forLanguageTag(localeTag)
                        val languageStatus = tts.setLanguage(locale)
                        if (languageStatus == TextToSpeech.LANG_MISSING_DATA ||
                            languageStatus == TextToSpeech.LANG_NOT_SUPPORTED) {
                            result.success(false)
                        } else {
                            result.success(tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "offline-fallback"))
                        }
                    }
                }
                "pause", "stop" -> {
                    tts?.stop()
                    result.success(null)
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
                        val request = OneTimeWorkRequestBuilder<BackgroundChapterWorker>()
                            .setInputData(Data.Builder()
                                .putString(BackgroundChapterWorker.KEY_TEXT, text)
                                .putString(BackgroundChapterWorker.KEY_VOICE, voice)
                                .putString(BackgroundChapterWorker.KEY_OUTPUT, outputPath)
                                .build())
                            .build()
                        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                            jobId, ExistingWorkPolicy.KEEP, request,
                        )
                        result.success(true)
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

        // Chaquopy needs to be started exactly once per process.
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val py = Python.getInstance()
                val entrypoints = py.getModule(PY_MODULE)
                when (call.method) {
                    "bootstrap" -> {
                        val version = entrypoints.callAttr("bootstrap").toString()
                        result.success(version)
                    }
                    "parseEpub" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_ARGS", "parseEpub requires a non-empty 'path' argument", null)
                            return@setMethodCallHandler
                        }
                        val json = entrypoints.callAttr("parse_epub_to_json", path).toString()
                        result.success(json)
                    }
                    "convertChapter" -> {
                        val text = call.argument<String>("text") ?: ""
                        val voice = call.argument<String>("voice") ?: "pt-BR-AntonioNeural"
                        val outputPath = call.argument<String>("outputPath") ?: ""
                        if (text.isBlank() || outputPath.isBlank()) {
                            result.error("BAD_ARGS", "text and outputPath required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val res = entrypoints.callAttr("convert_chapter", text, voice, outputPath)
                                val jsonStr = py.getBuiltins().callAttr("str", res).toString()
                                    .replace("'", "\"")
                                    .replace("True", "true")
                                    .replace("False", "false")
                                mainHandler.post { result.success(jsonStr) }
                            } catch (e: Throwable) {
                                mainHandler.post { result.error("PYTHON_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                    "detectLanguage" -> {
                        val text = call.argument<String>("text") ?: ""
                        result.success(entrypoints.callAttr("detect_language", text).toString())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("PYTHON_ERROR", e.message ?: e.javaClass.simpleName, e.stackTraceToString())
            }
        }
    }

    override fun onDestroy() {
        offlineTts?.stop()
        offlineTts?.shutdown()
        offlineTts = null
        super.onDestroy()
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
            // codeql[java/android/unsafe-content-uri-resolution]: `uri` passed
            // `isTrustedContentUri` before any ContentResolver access.
            contentResolver.openInputStream(uri)?.use { input ->
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
            // codeql[java/android/unsafe-content-uri-resolution]: `uri` passed
            // `isTrustedContentUri` before any ContentResolver access.
            val header = contentResolver.openInputStream(uri)?.use { it.readNBytes(8) } ?: return null
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
