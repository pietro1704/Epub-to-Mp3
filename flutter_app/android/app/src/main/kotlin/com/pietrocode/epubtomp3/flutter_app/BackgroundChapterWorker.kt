package com.pietrocode.epubtomp3.flutter_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters


class BackgroundChapterWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val text = inputData.getString(KEY_TEXT).orEmpty()
        val voice = inputData.getString(KEY_VOICE).orEmpty()
        val outputPath = inputData.getString(KEY_OUTPUT).orEmpty()
        if (text.isBlank() || voice.isBlank() || outputPath.isBlank()) return Result.failure()
        setForeground(createForegroundInfo())
        return Result.failure()
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
        const val KEY_TEXT = "text"
        const val KEY_VOICE = "voice"
        const val KEY_OUTPUT = "outputPath"
        const val CHANNEL_ID = "epub_to_mp3_conversion"
        const val NOTIFICATION_ID = 2401
    }
}
