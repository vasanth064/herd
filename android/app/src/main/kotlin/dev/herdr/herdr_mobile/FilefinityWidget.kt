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
import java.text.NumberFormat
import kotlin.concurrent.thread

class FilefinityWidget : AppWidgetProvider() {
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
                    val n = NumberFormat.getIntegerInstance()
                    views.setTextViewText(R.id.ff_posts, n.format(d.getLong("totalPosts")))
                    views.setTextViewText(R.id.ff_downloads, n.format(d.getLong("totalDownloads")))
                    views.setTextViewText(R.id.ff_users, n.format(d.getLong("totalUsers")))
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
