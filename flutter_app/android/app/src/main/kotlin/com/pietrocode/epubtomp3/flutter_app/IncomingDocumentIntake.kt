package com.pietrocode.epubtomp3.flutter_app

import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Environment
import android.provider.OpenableColumns

import android.util.Log

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.Locale

/**
 * Hosts Flutter and Android document ingestion.
 * Incoming content URIs are copied into app-private storage before they are
 * exposed to Dart, because a content URI is not a durable filesystem path.
 */
internal class IncomingDocumentIntake(
    private val activity: MainActivity,
    private val converterExecutor: java.util.concurrent.ExecutorService,
) {
    private val methodChannels = mutableListOf<MethodChannel>()
    private val eventChannels = mutableListOf<EventChannel>()
    private val embeddedLogTag = "EmbeddedConverter"
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val DOCUMENT_CHANNEL = "epub_to_mp3/incoming_documents"
        private const val DOCUMENT_EVENTS_CHANNEL = "epub_to_mp3/incoming_documents/events"
        private const val DEEP_LINK_EVENTS_CHANNEL = "epub_to_mp3/deep_links"
        private const val DOCUMENT_QUEUE = "incoming_documents.v1"
        private const val DOCUMENT_DIR = "incoming_documents"
        private const val DOCUMENT_PICKER_REQUEST = 4107
        private const val MAX_IMPORT_BYTES = 512L * 1024L * 1024L
    }

    private val incomingDocumentUriPolicy by lazy {
        IncomingDocumentUriPolicy(listOf(Environment.getExternalStorageDirectory()))
    }
    private var documentEvents: EventChannel.EventSink? = null
    private var deepLinkEvents: EventChannel.EventSink? = null
    private var pendingDocumentPickerResult: MethodChannel.Result? = null
    private val pendingDeepLinks = mutableListOf<String>()

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != DOCUMENT_PICKER_REQUEST) return
        val callback = pendingDocumentPickerResult ?: return
        pendingDocumentPickerResult = null
        if (resultCode != android.app.Activity.RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }
        val uri = data.data!!
        val document = copyIntoPrivateStorage(uri, activity.contentResolver.getType(uri))
        if (document == null) {
            callback.error("DOCUMENT_IMPORT_FAILED", "Could not copy the selected document", null)
        } else {
            callback.success(document.first)
        }
    }

    fun configure(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_EVENTS_CHANNEL
        ).also { eventChannels.add(it) }.setStreamHandler(object : EventChannel.StreamHandler {
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
        ).also { eventChannels.add(it) }.setStreamHandler(object : EventChannel.StreamHandler {
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
        ).also { methodChannels.add(it) }.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> {
                    Log.i(embeddedLogTag, "native document picker requested")
                    if (pendingDocumentPickerResult != null) {
                        result.error("PICKER_BUSY", "A document picker is already open", null)
                    } else {
                        pendingDocumentPickerResult = result
                        activity.startActivityForResult(
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

    }

    fun handleIncomingIntent(incoming: Intent?) {
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
        val target = File(File(activity.filesDir, DOCUMENT_DIR), "${safeBase}_$sourceKey$extension")
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
        val cursor: Cursor = activity.contentResolver.query(
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
                "content" -> activity.contentResolver.openInputStream(uri)
                "file" -> File(uri.path!!).canonicalFile.inputStream()
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readQueueObjects(): JSONArray = try {
        JSONArray(activity.getPreferences(android.content.Context.MODE_PRIVATE).getString(DOCUMENT_QUEUE, "[]"))
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
        activity.getPreferences(android.content.Context.MODE_PRIVATE).edit().putString(DOCUMENT_QUEUE, queue.toString()).apply()
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

    fun close() {
        methodChannels.forEach { it.setMethodCallHandler(null) }
        methodChannels.clear()
        eventChannels.forEach { it.setStreamHandler(null) }
        eventChannels.clear()
        documentEvents = null
        deepLinkEvents = null
        pendingDeepLinks.clear()
        pendingDocumentPickerResult?.error("ACTIVITY_DESTROYED", "Document picker closed", null)
        pendingDocumentPickerResult = null
    }
}
