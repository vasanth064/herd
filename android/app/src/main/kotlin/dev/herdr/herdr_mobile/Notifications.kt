package dev.herdr.herdr_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.RemoteInput
import android.os.Build

object Notifications {
    const val CHANNEL_AGENTS = "agents"
    const val CHANNEL_SERVICE = "service"
    private const val REPLY_KEY = "reply"

    private val queue = mutableListOf<Map<String, String>>()

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_AGENTS, "Agents", NotificationManager.IMPORTANCE_HIGH),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_SERVICE, "Connection", NotificationManager.IMPORTANCE_LOW),
        )
    }

    fun post(context: Context, args: Map<*, *>) {
        ensureChannels(context)
        val pane = args["pane"] as String
        val title = args["title"] as String
        val text = args["text"] as String
        val keys = (args["keys"] as? List<*>)?.map { it as String } ?: emptyList()
        val reply = args["reply"] as? Boolean ?: false

        val open = PendingIntent.getActivity(
            context,
            pane.hashCode(),
            Intent(context, MainActivity::class.java)
                .putExtra("pane", pane)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = Notification.Builder(context, CHANNEL_AGENTS)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentIntent(open)
            .setAutoCancel(true)

        for (key in keys) {
            builder.addAction(action(context, pane, "key", key, key))
        }
        if (reply) {
            builder.addAction(
                Notification.Action.Builder(null, "Reply", broadcast(context, pane, "text", ""))
                    .addRemoteInput(
                        RemoteInput.Builder(REPLY_KEY).setLabel("Reply to agent").build(),
                    )
                    .build(),
            )
        }

        context.getSystemService(NotificationManager::class.java)
            .notify(pane.hashCode(), builder.build())
    }

    fun cancel(context: Context, pane: String) {
        context.getSystemService(NotificationManager::class.java).cancel(pane.hashCode())
    }

    fun takeActions(): List<Map<String, String>> = synchronized(queue) {
        val taken = queue.toList()
        queue.clear()
        taken
    }

    private fun enqueue(item: Map<String, String>) {
        synchronized(queue) { queue.add(item) }
        HerdApplication.wake()
    }

    private fun action(
        context: Context,
        pane: String,
        kind: String,
        value: String,
        label: String,
    ): Notification.Action = Notification.Action.Builder(
        null,
        label,
        broadcast(context, pane, kind, value),
    ).build()

    private fun broadcast(
        context: Context,
        pane: String,
        kind: String,
        value: String,
    ): PendingIntent {
        val intent = Intent(context, ActionReceiver::class.java)
            .setAction("$pane|$kind|$value")
            .putExtra("pane", pane)
            .putExtra("kind", kind)
            .putExtra("value", value)
        // Mutable so the system can attach the typed reply.
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    class ActionReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val pane = intent.getStringExtra("pane") ?: return
            val kind = intent.getStringExtra("kind") ?: return
            val typed = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_KEY)
            val value = typed?.toString() ?: intent.getStringExtra("value") ?: ""
            if (kind == "text" && value.isBlank()) return
            enqueue(mapOf("pane" to pane, "kind" to kind, "value" to value))
            cancel(context, pane)
        }
    }
}
