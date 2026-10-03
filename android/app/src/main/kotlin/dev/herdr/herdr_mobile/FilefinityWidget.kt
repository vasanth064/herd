package dev.herdr.herdr_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlin.concurrent.thread

class FilefinityWidget : AppWidgetProvider() {
    private fun short(n: Long): String = when {
        n < 1_000 -> "$n"
        n < 1_000_000 -> String.format(Locale.US, "%.2fk", n / 1e3)
        else -> String.format(Locale.US, "%.2fM", n / 1e6)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val done = goAsync()
        thread {
            try {
                val views = RemoteViews(context.packageName, R.layout.filefinity_widget)
                try {
                    val c = URL("https://api.filefinity.com/api/v1/analytics/public")
                        .openConnection() as HttpURLConnection
                    c.connectTimeout = 10_000
                    c.readTimeout = 10_000
                    val d = JSONObject(c.inputStream.bufferedReader().readText())
                        .getJSONObject("data")
                    views.setTextViewText(R.id.ff_posts, short(d.getLong("totalPosts")))
                    views.setTextViewText(R.id.ff_downloads, short(d.getLong("totalDownloads")))
                    views.setTextViewText(R.id.ff_users, short(d.getLong("totalUsers")))
                } catch (e: Exception) {
                    views.setTextViewText(R.id.ff_title, "Filefinity · offline")
                }
                val tap = Intent(context, FilefinityWidget::class.java)
                    .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                views.setOnClickPendingIntent(
                    R.id.ff_root,
                    PendingIntent.getBroadcast(
                        context, 0, tap,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                manager.updateAppWidget(ids, views)
            } finally {
                done.finish()
            }
        }
    }
}
