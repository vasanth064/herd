package dev.herdr.herdr_mobile

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// Android freezes a cached process within seconds of the activity stopping, and
/// a frozen isolate can neither pump a forwarded socket nor notice an agent
/// asking a question. Foreground importance is the only thing that prevents it.
class HerdService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifications.ensureChannels(this)
        val text = intent?.getStringExtra("text") ?: "Connected"

        val tap = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = Notification.Builder(this, Notifications.CHANNEL_SERVICE)
            .setContentTitle("Herd")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val ID = 1

        fun start(context: Context, text: String) {
            val intent = Intent(context, HerdService::class.java).putExtra("text", text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, HerdService::class.java))
        }
    }
}
