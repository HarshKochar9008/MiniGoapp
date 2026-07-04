package com.Zen.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val shareChannel = "minigo/native_share"
    private val widgetChannel = "minigo/widget"
    private val shareIntentChannel = "minigo/share_intent"

    // Last widget action from the intent that launched (or re-launched) this activity
    private var pendingWidgetAction: String? = null

    // Files shared to us from another app's share sheet, waiting for Flutter to collect
    private val pendingSharedUris = mutableListOf<Uri>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureShareIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "shareText") {
                    val text = call.argument<String>("text")
                    val subject = call.argument<String>("subject")
                    if (text.isNullOrBlank()) {
                        result.error("invalid_args", "Missing text", null)
                        return@setMethodCallHandler
                    }
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                        putExtra(Intent.EXTRA_SUBJECT, subject)
                    }
                    startActivity(Intent.createChooser(shareIntent, "Share via"))
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, widgetChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Flutter calls this after identity loads to push the code to the widget
                    "refreshWidget" -> {
                        MinigoWidgetProvider.refreshAll(this)
                        result.success(null)
                    }
                    // Flutter calls this on start to check if the app was opened from a widget button
                    "getAndClearAction" -> {
                        val action = pendingWidgetAction ?: intent?.getStringExtra("widget_action")
                        pendingWidgetAction = null
                        result.success(action)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareIntentChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getAndClearSharedFiles") {
                    val uris = pendingSharedUris.toList()
                    pendingSharedUris.clear()
                    if (uris.isEmpty()) {
                        result.success(emptyList<Map<String, Any>>())
                        return@setMethodCallHandler
                    }
                    // Copy off the main thread — shared videos can be large
                    Thread {
                        val files = copySharedUrisToCache(uris)
                        Handler(Looper.getMainLooper()).post { result.success(files) }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Capture widget action when app is already running and user taps a widget button
        val action = intent.getStringExtra("widget_action")
        if (action != null) pendingWidgetAction = action
        captureShareIntent(intent)
    }

    private fun captureShareIntent(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) pendingSharedUris.add(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: List<Uri>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (uris != null) pendingSharedUris.addAll(uris)
            }
        }
    }

    /// Content URIs from other apps are only readable while our grant lasts,
    /// so copy each stream into our own cache before handing paths to Flutter.
    private fun copySharedUrisToCache(uris: List<Uri>): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val dir = File(cacheDir, "shared_in").apply { mkdirs() }
        for ((index, uri) in uris.withIndex()) {
            try {
                val name = sanitizeFileName(
                    queryDisplayName(uri)
                        ?: uri.lastPathSegment?.substringAfterLast('/')
                        ?: "shared_file_$index"
                )
                val target = File(dir, "${System.currentTimeMillis()}_${index}_$name")
                val copied = contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(target).use { output -> input.copyTo(output) }
                    true
                } ?: false
                if (copied) {
                    out.add(
                        mapOf(
                            "path" to target.absolutePath,
                            "name" to name,
                            "size" to target.length(),
                        )
                    )
                }
            } catch (_: Exception) {
                // Skip unreadable entries; Flutter shows whatever copied successfully
            }
        }
        return out
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw.replace(Regex("""[\\/:*?"<>|]"""), "_").trim()
        return if (cleaned.isEmpty()) "shared_file" else cleaned
    }
}
