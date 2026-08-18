package dev.herdr.herdr_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/// Uses the engine created in [HerdApplication] rather than its own, so closing
/// the app leaves the isolate — and every open forward — running.
class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = HerdApplication.ENGINE

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        askForNotifications()
    }

    /// Denying leaves the foreground service running, so forwards still work —
    /// but agent alerts are the point now, so ask up front rather than later.
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(permission), 0)
    }
}
