package dev.herdr.herdr_mobile

import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel

/// The Dart isolate has to outlive the activity: an agent that blocks while the
/// app is closed still has to raise a notification, and answering it from the
/// notification needs an SSH connection that only Dart has.
class HerdApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()

        val engine = FlutterEngine(this)
        // Before the entrypoint runs — main() reads stored profiles through
        // shared_preferences on its first line.
        GeneratedPluginRegistrant.registerWith(engine)

        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "service.start" -> {
                        HerdService.start(this, call.argument<String>("text") ?: "Connected")
                        result.success(null)
                    }
                    "service.stop" -> {
                        HerdService.stop(this)
                        result.success(null)
                    }
                    "notify" -> {
                        Notifications.post(this, call.arguments as Map<*, *>)
                        result.success(null)
                    }
                    "cancel" -> {
                        Notifications.cancel(this, call.argument<String>("pane")!!)
                        result.success(null)
                    }
                    "takeActions" -> result.success(Notifications.takeActions())
                    else -> result.notImplemented()
                }
            }
        }

        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE, engine)
    }

    companion object {
        const val ENGINE = "main"
        private const val CHANNEL = "herd/native"

        private var channel: MethodChannel? = null

        /// Dart drains the queue itself; this only nudges it awake. A tap that
        /// lands before Dart is listening stays queued rather than vanishing.
        fun wake() {
            channel?.invokeMethod("wake", null)
        }
    }
}
