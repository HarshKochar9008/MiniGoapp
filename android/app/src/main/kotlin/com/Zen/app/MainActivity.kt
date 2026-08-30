package com.Zen.app

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val shareChannel = "minigo/native_share"
    private val widgetChannel = "minigo/widget"
    private val shareIntentChannel = "minigo/share_intent"
    private val saveChannel = "minigo/native_save"

    // Last widget action from the intent that launched (or re-launched) this activity
    private var pendingWidgetAction: String? = null

    // Files shared to us from another app's share sheet, waiting for Flutter to collect
    private val pendingSharedUris = mutableListOf<Uri>()

    // Deep link (minigo://…) that launched or re-launched the app
    private var pendingDeepLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureShareIntent(intent)
        captureDeepLink(intent)
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
                when (call.method) {
                    "getAndClearSharedFiles" -> {
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
                    }
                    "getAndClearDeepLink" -> {
                        val link = pendingDeepLink
                        pendingDeepLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, saveChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType")
                        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("invalid_args", "Missing sourcePath or fileName", null)
                            return@setMethodCallHandler
                        }
                        // A received file can be hundreds of MB; copy off the main thread.
                        Thread {
                            var saved: String? = null
                            var failure: Exception? = null
                            try {
                                saved = saveToDownloads(sourcePath, fileName, mimeType)
                            } catch (e: Exception) {
                                failure = e
                            }
                            val location = saved
                            val error = failure
                            Handler(Looper.getMainLooper()).post {
                                when {
                                    location != null -> result.success(location)
                                    error is SecurityException ->
                                        result.error("permission_denied", error.message, null)
                                    else ->
                                        result.error(
                                            "save_failed",
                                            error?.message ?: "Unknown error",
                                            null,
                                        )
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Capture widget action when app is already running and user taps a widget button
        val action = intent.getStringExtra("widget_action")
        if (action != null) pendingWidgetAction = action
        captureShareIntent(intent)
        captureDeepLink(intent)
    }

    private fun captureDeepLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val data = intent.data ?: return
        if (data.scheme == "minigo") pendingDeepLink = data.toString()
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

    /// Copies [sourcePath] into the public Downloads collection and returns a
    /// label for the UI.
    ///
    /// `WRITE_EXTERNAL_STORAGE` is capped at API 29 in the manifest, so writing
    /// to `/storage/emulated/0/Download` by path fails on anything newer.
    /// MediaStore is the supported route there and needs no permission for our
    /// own entries; below API 29 the legacy public directory is the only one.
    private fun saveToDownloads(sourcePath: String, fileName: String, mimeType: String?): String {
        val source = File(sourcePath)
        if (!source.exists()) throw IOException("The downloaded file is no longer available")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                if (!mimeType.isNullOrBlank()) put(MediaStore.Downloads.MIME_TYPE, mimeType)
                // Stays hidden from other apps until the bytes are all written.
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = contentResolver.insert(collection, values)
                ?: throw IOException("Downloads is not writable on this device")
            try {
                contentResolver.openOutputStream(uri)?.use { output ->
                    FileInputStream(source).use { input -> input.copyTo(output) }
                } ?: throw IOException("Could not open Downloads for writing")
            } catch (e: Exception) {
                // Never leave a half-written pending row behind.
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
                throw e
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return "Downloads"
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("Storage permission is required to save to Downloads")
        }
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("Could not open the Downloads folder")
        }
        val target = uniqueFile(dir, fileName)
        FileInputStream(source).use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        // Pre-Q there is no MediaStore row yet, so file managers need a nudge.
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), null, null)
        return "Downloads"
    }

    /// Suffixes `_(1)`, `_(2)`, … until the name is free. Only needed on the
    /// legacy path — MediaStore uniquifies display names itself.
    private fun uniqueFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate

        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var counter = 1
        do {
            candidate = File(dir, "${base}_($counter)$ext")
            counter++
        } while (candidate.exists())
        return candidate
    }

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw.replace(Regex("""[\\/:*?"<>|]"""), "_").trim()
        return if (cleaned.isEmpty()) "shared_file" else cleaned
    }
}
