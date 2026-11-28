package com.pietrocode.epubtomp3.flutter_app

import android.os.Handler
import android.os.Looper

import android.util.Log

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal class FlutterConversionChannels(private val activity: MainActivity) {
    private val methodChannels = mutableListOf<MethodChannel>()
    private val eventChannels = mutableListOf<EventChannel>()
    private val embeddedLogTag = "EmbeddedConverter"
    internal val executor = Executors.newSingleThreadExecutor()
    private val converterExecutor get() = executor
    // Read-only lookups (catalog, metadata, parse, renames) must not wait for a running conversion,
    // which holds the single converter thread for minutes.
    private val queryExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val replies = ChannelReplies()
    private var audioChunkSink: EventChannel.EventSink? = null
    internal var platformVoiceEvents: EventChannel.EventSink? = null
    private val activeConversions = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val models = ConversionModelChannels(activity, executor, queryExecutor)
    private val EMBEDDED_CHANNEL = "epub_to_mp3/embedded_converter"
    private val EMBEDDED_UNAVAILABLE = "EMBEDDED_CONVERTER_UNAVAILABLE"

    // Rust waits for main-thread delivery so chunk events precede the final result.
    fun onNativeAudioChunk(requestId: String, chapterIndex: Int, chunkIndex: Int, path: String): Boolean {
        if (!activeConversions.containsKey(requestId)) return false
        val completed = java.util.concurrent.CountDownLatch(1)
        val accepted = java.util.concurrent.atomic.AtomicBoolean(false)
        mainHandler.post {
            try {
                val sink = audioChunkSink
                if (sink != null && activeConversions.containsKey(requestId)) {
                    sink.success(mapOf("requestId" to requestId, "chapterIndex" to chapterIndex, "chunkIndex" to chunkIndex, "path" to path))
                    accepted.set(true)
                }
            } catch (error: Throwable) {
                Log.e(embeddedLogTag, "Audio chunk delivery failed", error)
            } finally { completed.countDown() }
        }
        return completed.await(5, TimeUnit.SECONDS) && accepted.get()
    }

    fun configure(flutterEngine: FlutterEngine) {
        with(activity) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_to_mp3/audio_chunks").also { eventChannels.add(it) }.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { audioChunkSink = events }
                override fun onCancel(arguments: Any?) { audioChunkSink = null }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "epub_to_mp3/platform_voice").also { eventChannels.add(it) }.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { platformVoiceEvents = events }
                override fun onCancel(arguments: Any?) { platformVoiceEvents = null }
            })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EMBEDDED_CHANNEL
        ).also { methodChannels.add(it) }.setMethodCallHandler { call, originalResult ->
            val result = replies.track(originalResult)
            Log.i(embeddedLogTag, "method ${call.method} received")
            when (call.method) {
                "streamReady" -> result.success(audioChunkSink != null)
                "cancelConversion" -> {
                    val input = call.argument<String>("inputPath")
                    val output = call.argument<String>("outputPath")
                    activeConversions.filter { (path, source) -> if (output != null) path == output else input == null || source == input }.keys.forEach { path -> activeConversions.remove(path); nativeCancelConversion(path) }
                    result.success(null)
                }
                "status" -> {
                    Log.i(embeddedLogTag, "status requested")
                    result.success(embeddedConverterStatus())
                }
                "jobLog" -> {
                    val jobId = call.argument<String>("jobId")
                    if (jobId.isNullOrBlank()) result.error("BAD_ARGS", "jobId is required", null)
                    else runQuery(result) {
                        val value = nativeJobLog(jobId)
                        runOnUiThread {
                            if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                            else result.success(value)
                        }
                    }
                }
                "parse" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val inputPath = call.argument<String>("inputPath")
                        if (inputPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "inputPath is required", null)
                        } else {
                            Log.i(embeddedLogTag, "parse start input=$inputPath")
                            runQuery(result) {
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
                "libraryMetadata" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val inputPath = call.argument<String>("inputPath")
                        if (inputPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "inputPath is required", null)
                        } else {
                            runQuery(result) {
                                try {
                                    val native = nativeLibraryMetadata(inputPath)
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
                "chapterNames", "filenameCover" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val isNames = call.method == "chapterNames"
                        val key = if (isNames) "path" else "fileName"
                        val value = call.argument<String>(key)
                        if (value.isNullOrBlank()) {
                            result.error("BAD_ARGS", "$key is required", null)
                        } else {
                            val index = call.argument<String>("index")
                            val name = call.argument<String>("name")
                            runQuery(result) {
                                try {
                                    val native = if (isNames) nativeChapterNames(value, index, name) else nativeFilenameCover(value)
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
                "pdfImagePages", "pdfOcrPageSet" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val path = call.argument<String>("path")
                        val page = call.argument<String>("page")
                        val text = call.argument<String>("text")
                        val isPages = call.method == "pdfImagePages"
                        if (path.isNullOrBlank() || (!isPages && page.isNullOrBlank())) {
                            result.error("BAD_ARGS", "path" + (if (isPages) "" else " and page") + " required", null)
                        } else {
                            runQuery(result) {
                                try {
                                    val native = if (isPages) nativePdfImagePages(path) else nativePdfOcrPageSet(path, page!!, text)
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
                "exportMp3" -> {
                    val request = call.argument<String>("request")
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else if (request.isNullOrBlank()) {
                        result.error("BAD_ARGS", "request is required", null)
                    } else {
                        // Joining a whole book is slow: keep it off the converter thread and the UI.
                        runQuery(result) {
                            try {
                                val native = nativeExportMp3(request)
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
                "convert" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val inputPath = call.argument<String>("inputPath")
                        val outputPath = call.argument<String>("outputPath")
                        if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "inputPath and outputPath are required", null)
                        } else {
                            activeConversions[outputPath] = inputPath
                            nativePrepareConversion(outputPath)
                            runNative(result) {
                                try {
                                    Log.i(embeddedLogTag, "convert start input=$inputPath output=$outputPath")
                                    // Rust resolves the immutable provider selection for this job.
                                    Log.i(embeddedLogTag, "convert invoking JNI libraryLoaded=${MainActivity.converterLibraryLoaded}")
                                    val chapterStart = call.argument<Int>("chapterStart") ?: -1
                                    val chapterEnd = call.argument<Int>("chapterEnd") ?: -1
                                    val isolatedExecutor = Executors.newSingleThreadExecutor()
                                    // converter_last_error is thread-local. Read it on the
                                    // same worker thread immediately after nativeConvert;
                                    // reading it after Future.get would lose the real error.
                                    val nativeFuture = isolatedExecutor.submit<Pair<String?, String?>> {
                                        val value = nativeConvertWithOptions(inputPath, outputPath, chapterStart, chapterEnd, conversionOptions(call.argument<String>("optionsJson")), call.argument<Boolean>("streaming") == true, call.argument<Int>("textOffset") ?: -1)
                                        value to if (value == null) nativeLastError() else null
                                    }
                                    // A complete EPUB can legitimately take several minutes on
                                    // legacy hardware when Edge processes chapters serially. Keep
                                    // the watchdog finite, but do not abort a valid long-running
                                    // conversion after the old one-chapter timeout.
                                    val (native, nativeError) = try {
                                        NativeConversionAwait.await(nativeFuture, outputPath, ::nativeCancelConversion)
                                    } catch (_: TimeoutException) {
                                        Log.e(embeddedLogTag, "embedded conversion timed out after ${NativeConversionAwait.TIMEOUT_SECONDS} seconds")
                                        runOnUiThread {
                                            result.error(
                                                "EMBEDDED_CONVERSION_TIMEOUT",
                                                "Embedded conversion timed out after ${NativeConversionAwait.TIMEOUT_SECONDS} seconds",
                                                null
                                            )
                                        }
                                        return@runNative
                                    } finally {
                                        isolatedExecutor.shutdownNow()
                                        activeConversions.remove(outputPath)
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
                else -> if (!models.dispatch(call, result)) result.notImplemented()
            }
        }        }
    }

    fun close() {
        models.close()
        methodChannels.forEach { it.setMethodCallHandler(null) }
        methodChannels.clear()
        eventChannels.forEach { it.setStreamHandler(null) }
        eventChannels.clear()
        activeConversions.keys.forEach { activity.nativeCancelConversion(it) }
        activeConversions.clear()
        audioChunkSink = null
        platformVoiceEvents = null
        replies.close()
        executor.shutdownNow()
        queryExecutor.shutdownNow()
    }
    private fun runQuery(result: MethodChannel.Result, action: () -> Unit) = runOn(queryExecutor, result, action)

    private fun runNative(result: MethodChannel.Result, action: () -> Unit) = runOn(converterExecutor, result, action)

    private fun runOn(pool: java.util.concurrent.ExecutorService, result: MethodChannel.Result, action: () -> Unit) {
        try {
            pool.execute {
                try {
                    action()
                } catch (error: Throwable) {
                    activity.runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error.message, null) }
                }
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            result.error("ACTIVITY_DESTROYED", "Activity closed before the request completed", null)
        }
    }
}
