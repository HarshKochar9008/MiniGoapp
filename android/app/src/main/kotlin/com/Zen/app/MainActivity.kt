package com.Zen.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val shareChannel = "whoosh/native_share"
    private val widgetChannel = "whoosh/widget"

    // Last widget action from the intent that launched (or re-launched) this activity
    private var pendingWidgetAction: String? = null

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
                        WhooshWidgetProvider.refreshAll(this)
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Capture widget action when app is already running and user taps a widget button
        val action = intent.getStringExtra("widget_action")
        if (action != null) pendingWidgetAction = action
    }
}
