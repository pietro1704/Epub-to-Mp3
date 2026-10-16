package com.pietrocode.epubtomp3.flutter_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.Data
import org.json.JSONObject


class BackgroundChapterWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val payloadPath = inputData.getString(KEY_PAYLOAD).orEmpty()
        val payload = try {
            JSONObject(File(payloadPath).readText(Charsets.UTF_8))
        } catch (_: Exception) {
            return Result.failure()
        }
        val inputPath = payload.optString("inputPath")
        val chapterIndex = payload.optInt("chapterIndex", -1)
        val outputPath = payload.optString("outputPath")
        val optionsJson = payload.optString("optionsJson")
        if (inputPath.isBlank() || chapterIndex < 0 || outputPath.isBlank() || optionsJson.isBlank()) return Result.failure()
        return try {
            var nativeResultPath: String? = null
            setForeground(createForegroundInfo())
            watchBackgroundNativeCancellation(nativeExecution) {
                withContext(Dispatchers.IO) {
                    coroutineContext.ensureActive()
                    System.loadLibrary("converter_ffi")
                    val preparedOptions = NativeTtsOptions.prepare(applicationContext, optionsJson)
                    val result = nativeExecution.run(outputPath, { coroutineContext.ensureActive() }) {
                        nativeConvertWithOptions(inputPath, outputPath, chapterIndex, chapterIndex, preparedOptions, false)
                            ?: throw IllegalStateException("Embedded Rust conversion failed")
                    }
                    coroutineContext.ensureActive()
                    // Preserve the complete native receipt, including actual voices and opaque policy state.
                    val resultDirectory = File(outputPath).apply { mkdirs() }
                    nativeResultPath = BackgroundPayloadStore.persist(resultDirectory, "background-result-$id", result).absolutePath
                }
            }
            Result.success(Data.Builder().putString(KEY_NATIVE_RESULT_PATH, nativeResultPath).build())
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            nativeExecution.stop()
            throw cancelled
        } catch (_: Exception) { Result.failure() }
    }

    private val nativeExecution by lazy {
        BackgroundNativeExecution(::nativePrepareConversion, ::nativeCancelConversion)
    }
    private external fun nativePrepareConversion(outputPath: String)
    private external fun nativeConvertWithOptions(inputPath: String, outputPath: String, chapterStart: Int, chapterEnd: Int, optionsJson: String, streaming: Boolean): String?
    private external fun nativeCancelConversion(outputPath: String): Boolean

    private fun createForegroundInfo(): ForegroundInfo {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Audiobook conversion", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Converting audiobook")
            .setContentText("Working in background")
            .setOngoing(true)
            .build()
        return ForegroundInfo(NOTIFICATION_ID, notification)
    }

    companion object {
        const val KEY_PAYLOAD = "payloadPath"
        const val KEY_NATIVE_RESULT_PATH = "nativeResultPath"
        const val KEY_BACKEND_URL = "backendUrl"
        const val PREFERENCES = "flutter_epub_to_mp3"
        const val REQUEST_TIMEOUT_MS = 120_000
        const val CHANNEL_ID = "epub_to_mp3_conversion"
        const val NOTIFICATION_ID = 2401
    }
}
