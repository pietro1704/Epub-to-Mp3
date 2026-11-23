package com.pietrocode.epubtomp3.flutter_app


import android.os.Build
import android.util.Log

import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal class ConversionModelChannels(
    private val activity: MainActivity,
    private val converterExecutor: java.util.concurrent.ExecutorService,
) {
    private val embeddedLogTag = "EmbeddedConverter"
    private val EMBEDDED_UNAVAILABLE = "EMBEDDED_CONVERTER_UNAVAILABLE"

    fun dispatch(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result): Boolean {
        with(activity) {
            when (call.method) {
                "ttsModels" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        runNative(result) {
                            val value = nativeTtsCatalogV3()
                            runOnUiThread {
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(org.json.JSONObject(value).put("android_api", android.os.Build.VERSION.SDK_INT).toString())
                            }
                        }
                    }
                }
                "ttsManualModels" -> {
                    val root = call.argument<String>("root")
                    if (root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "root is required", null)
                    } else {
                        runManualModelRequest(result) {
                            nativeTtsManualCatalogV3(
                                Locale.getDefault().toLanguageTag(),
                                Build.VERSION.SDK_INT,
                                System.getProperty("os.arch").orEmpty(),
                                Build.VERSION.RELEASE,
                                root,
                            )
                        }
                    }
                }
                "ttsProbeModel" -> {
                    val modelId = call.argument<String>("modelId")
                    val root = call.argument<String>("root")
                    val language = call.argument<String>("language") ?: Locale.getDefault().toLanguageTag()
                    if (modelId.isNullOrBlank() || root.isNullOrBlank()) {
                        result.error("BAD_ARGS", "modelId and root are required", null)
                    } else {
                        runManualModelRequest(result) {
                            val espeakParent = NativeTtsOptions.preparePackagedEspeakData(applicationContext)
                            nativeTtsCatalogProbeModelV3(
                                language,
                                Build.VERSION.SDK_INT,
                                System.getProperty("os.arch").orEmpty(),
                                Build.VERSION.RELEASE,
                                root,
                                espeakParent.absolutePath,
                                modelId,
                            )
                        }
                    }
                }
                "ttsDefaultEngine" -> {
                    if (!MainActivity.converterLibraryAvailable()) {
                        result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
                    } else {
                        val language = call.argument<String>("language")
                        val platform = call.argument<String>("platform") ?: "android"
                        val androidApi = call.argument<Int>("androidApi") ?: android.os.Build.VERSION.SDK_INT
                        if (language.isNullOrBlank()) {
                            result.error("BAD_ARGS", "language is required", null)
                        } else {
                            runNative(result) {
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
                        runNative(result) {
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
                        runNative(result) {
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
                        runNative(result) {
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
                        runNative(result) {
                            val value = nativeTtsModelInstallCatalogManifest(modelId, root)
                            runOnUiThread {
                                Log.i(embeddedLogTag, "ttsModelInstallCatalogManifest completed model=$modelId value=${value != null}")
                                if (value == null) result.error(EMBEDDED_UNAVAILABLE, nativeLastError(), null)
                                else result.success(value)
                            }
                        }
                    }
                }
                "modelInstallOperation" -> {
                    val operation = call.argument<String>("op")
                    val handle = call.argument<Number>("handle")?.toLong() ?: 0L
                    if (operation == null) {
                        result.error("BAD_ARGS", "op is required", null)
                    } else {
                        runInstallOperation(result) { installOperation(operation, handle, call) }
                    }
                }
                "piperSynthesize" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val output = call.argument<String>("output").orEmpty()
                    Log.i(embeddedLogTag, "piperSynthesize start output=$output chars=${text.length}")
                    runNative(result) {
                        val isolatedExecutor = Executors.newSingleThreadExecutor()
                        try {
                            val nativeFuture = isolatedExecutor.submit<Pair<Boolean, String?>> {
                                val value = nativePiperSynthesizeWithOptions(text, output, conversionOptions(call.argument<String>("optionsJson")))
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
                        runNative(result) {
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
                        runNative(result) {
                            val removed = nativeTtsModelRemove(modelId, root)
                            runOnUiThread { result.success(removed) }
                        }
                    }
                }
                else -> return false
            }
        }
        return true
    }

    private fun runManualModelRequest(result: MethodChannel.Result, request: () -> String?) {
        if (!MainActivity.converterLibraryAvailable()) {
            result.error(EMBEDDED_UNAVAILABLE, "converter-ffi native library is not packaged in this APK", null)
            return
        }
        runNative(result) {
            val value = try {
                request()
            } catch (error: UnsatisfiedLinkError) {
                throw IllegalStateException("The embedded converter lacks version 3 manual TTS model support", error)
            }
            val error = if (value == null) activity.nativeLastError() else null
            activity.runOnUiThread {
                if (value == null) result.error(EMBEDDED_UNAVAILABLE, error, null)
                else result.success(value)
            }
        }
    }

    // Operations on a model install are short and ordered, so they get their own
    // thread instead of queueing behind a long conversion.
    private val installExecutor: java.util.concurrent.ExecutorService = Executors.newSingleThreadExecutor()

    fun close() {
        installExecutor.shutdown()
    }

    private fun runInstallOperation(result: MethodChannel.Result, action: () -> Any?) {
        try {
            installExecutor.execute {
                try {
                    val value = action()
                    activity.runOnUiThread { result.success(value) }
                } catch (error: Throwable) {
                    activity.runOnUiThread { result.error(EMBEDDED_UNAVAILABLE, error.message, null) }
                }
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            result.error("ACTIVITY_DESTROYED", "Activity closed before the request completed", null)
        }
    }

    /** Returns the JSON/path/handle result, or throws with the converter's last error. */
    private fun installOperation(operation: String, handle: Long, call: io.flutter.plugin.common.MethodCall): Any? = with(activity) {
        fun <T> converterValue(value: T?): T = value ?: throw IllegalStateException(nativeLastError())
        fun ensure(ok: Boolean) { if (!ok) throw IllegalStateException(nativeLastError()) }
        when (operation) {
            "create", "recover" -> {
                val modelId = call.argument<String>("modelId")
                val root = call.argument<String>("root")
                val available = call.argument<Number>("availableBytes")?.toLong() ?: 0L
                if (modelId.isNullOrBlank() || root.isNullOrBlank()) throw IllegalArgumentException("modelId and root are required")
                val created = nativeTtsModelInstallOperationCreate(modelId, root, available, operation == "recover")
                if (created == 0L) throw IllegalStateException(nativeLastError())
                created // -1 means a recover found nothing to resume.
            }
            "plan" -> converterValue(nativeTtsModelInstallOperationPlan(handle))
            "event" -> converterValue(nativeTtsModelInstallOperationEvent(handle))
            "recordProgress" -> {
                ensure(nativeTtsModelInstallOperationRecordProgress(
                    handle, call.argument<Int>("index") ?: -1, call.argument<Number>("bytes")?.toLong() ?: -1L))
                null
            }
            "accept" -> {
                ensure(nativeTtsModelInstallOperationAccept(handle, call.argument<Int>("index") ?: -1, call.argument<String>("path").orEmpty()))
                null
            }
            "publish" -> converterValue(nativeTtsModelInstallOperationPublish(handle))
            "fail" -> {
                ensure(nativeTtsModelInstallOperationFail(handle, call.argument<String>("kind").orEmpty(), call.argument<String>("message").orEmpty()))
                null
            }
            "cancel" -> { nativeTtsModelInstallOperationCancel(handle); null }
            "free" -> { nativeTtsModelInstallOperationFree(handle); null }
            "freeBytes" -> {
                val root = call.argument<String>("root").orEmpty()
                val directory = java.io.File(root).let { if (it.exists()) it else it.parentFile ?: it }
                android.os.StatFs(directory.absolutePath).availableBytes
            }
            else -> throw IllegalArgumentException("unknown install operation $operation")
        }
    }

    private fun runNative(result: MethodChannel.Result, action: () -> Unit) {
        try {
            converterExecutor.execute {
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
