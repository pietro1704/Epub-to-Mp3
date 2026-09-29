package com.pietrocode.epubtomp3.flutter_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
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
        val text = payload.optString("text")
        val voice = payload.optString("voice")
        val outputPath = payload.optString("outputPath")
        if (text.isBlank() || voice.isBlank() || outputPath.isBlank()) return Result.failure()
        return try {
            setForeground(createForegroundInfo())
            withContext(Dispatchers.IO) { convert_chapter(text, voice, outputPath) }
            Result.success()
        } catch (_: kotlinx.coroutines.CancellationException) {
            throw _
        } catch (_: Exception) {
            Result.failure()
        }
    }

    /** Calls the configured Rust HTTP backend and writes its MP3 result. */
    private suspend fun convert_chapter(text: String, voice: String, outputPath: String) {
        val backendUrl = applicationContext
            .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(KEY_BACKEND_URL, null)
            ?.trim()
            ?.trimEnd('/')
            ?: throw IllegalStateException("Backend URL is not configured")
        if (!backendUrl.startsWith("http://") && !backendUrl.startsWith("https://")) {
            throw IllegalArgumentException("Backend URL must use HTTP or HTTPS")
        }
        val payload = listOf(
            "text=${URLEncoder.encode(text, "UTF-8")}",
            "voice=${URLEncoder.encode(voice, "UTF-8")}",
            "output_path=${URLEncoder.encode(outputPath, "UTF-8")}",
        ).joinToString("&")
        val connection = (URL("$backendUrl/api/convert_chapter").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = REQUEST_TIMEOUT_MS
            readTimeout = REQUEST_TIMEOUT_MS
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        try {
            ensureActive()
            connection.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("Backend returned HTTP ${connection.responseCode}")
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            ensureActive()
            if (bytes.isEmpty()) throw IllegalStateException("Backend returned an empty result")
            val target = File(outputPath).apply {
                parentFile?.mkdirs()
            }
            val temp = File(target.parentFile, ".${target.name}.${System.nanoTime()}.tmp")
            try {
                temp.writeBytes(bytes)
                ensureActive()
                if (!temp.renameTo(target)) throw IOException("Could not atomically publish chapter audio")
            } finally { temp.delete() }
        } finally {
            connection.disconnect()
        }
    }

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
        const val KEY_BACKEND_URL = "backendUrl"
        const val PREFERENCES = "flutter_epub_to_mp3"
        const val REQUEST_TIMEOUT_MS = 120_000
        const val CHANNEL_ID = "epub_to_mp3_conversion"
        const val NOTIFICATION_ID = 2401
    }
}
