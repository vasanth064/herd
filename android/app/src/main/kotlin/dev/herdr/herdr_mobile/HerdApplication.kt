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
                    "capture" -> capture(call, result)
                    else -> result.notImplemented()
                }
            }
        }

        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE, engine)
    }

    /// Copies from Flutter's own SurfaceView: a whole-window copy comes back
    /// blank, and Dart's toImage cannot see a WebView's texture.
    private fun capture(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val root = activity?.get()?.window?.decorView
        val surface = root?.let { findSurface(it) }
        if (surface == null || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) {
            result.success(null)
            return
        }
        val r = android.graphics.Rect(
            call.argument<Int>("x")!!, call.argument<Int>("y")!!,
            call.argument<Int>("x")!! + call.argument<Int>("w")!!,
            call.argument<Int>("y")!! + call.argument<Int>("h")!!,
        )
        val bitmap = android.graphics.Bitmap.createBitmap(r.width(), r.height(), android.graphics.Bitmap.Config.ARGB_8888)
        android.view.PixelCopy.request(surface, r, bitmap, { code ->
            if (code != android.view.PixelCopy.SUCCESS) {
                result.success(null)
            } else {
                val out = java.io.ByteArrayOutputStream()
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                result.success(out.toByteArray())
            }
            bitmap.recycle()
        }, android.os.Handler(android.os.Looper.getMainLooper()))
    }

    private fun findSurface(v: android.view.View): android.view.SurfaceView? {
        if (v is android.view.SurfaceView) return v
        if (v is android.view.ViewGroup) {
            for (i in 0 until v.childCount) findSurface(v.getChildAt(i))?.let { return it }
        }
        return null
    }

    companion object {
        const val ENGINE = "main"

        var activity: java.lang.ref.WeakReference<android.app.Activity>? = null
        private const val CHANNEL = "herd/native"

        private var channel: MethodChannel? = null

        /// Dart drains the queue itself; this only nudges it awake. A tap that
        /// lands before Dart is listening stays queued rather than vanishing.
        fun wake() {
            channel?.invokeMethod("wake", null)
        }
    }
}
