package com.pietrocode.epubtomp3.flutter_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import org.json.JSONObject

class PlaybackWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { updateWidget(context, manager, it) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            refreshAll(context)
        }
    }

    companion object {
        const val ACTION_REFRESH = "com.pietrocode.epubtomp3.REFRESH_WIDGET"
        private const val PREFS = "FlutterSharedPreferences"
        private const val SNAPSHOT_KEY = "flutter.widget.playback_snapshot.v1"

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, PlaybackWidgetProvider::class.java)
            manager.getAppWidgetIds(component).forEach { updateWidget(context, manager, it) }
        }

        private fun updateWidget(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.playback_widget)
            val snapshot = readSnapshot(context)
            val title = snapshot?.optString("title").orEmpty()
            val chapter = snapshot?.optString("chapter").orEmpty()
            val playing = snapshot?.optBoolean("isPlaying", false) == true
            views.setTextViewText(R.id.widget_title, if (title.isBlank()) "EpubToMp3" else title)
            views.setTextViewText(R.id.widget_chapter, if (chapter.isBlank()) "Open player" else chapter)
            views.setTextViewText(R.id.widget_status, if (playing) "Playing" else "Paused")
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("epubtomp3://player"), context, MainActivity::class.java)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context, id, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            manager.updateAppWidget(id, views)
        }

        private fun readSnapshot(context: Context): JSONObject? = try {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(SNAPSHOT_KEY, null)
            if (raw.isNullOrBlank()) null else JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }
}
