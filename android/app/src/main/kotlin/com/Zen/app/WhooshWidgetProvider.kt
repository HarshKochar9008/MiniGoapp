package com.Zen.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import android.widget.Toast

class WhooshWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        ids.forEach {
            try {
                updateWidget(context, mgr, it)
            } catch (e: Exception) {
                android.util.Log.e("WhooshWidget", "onUpdate failed for id=$it", e)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_COPY) {
            val code = intent.getStringExtra(EXTRA_CODE) ?: return
            val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clip.setPrimaryClip(ClipData.newPlainText("Whoosh code", code))
            // Only show toast on older Android — 13+ shows its own clipboard banner
            if (Build.VERSION.SDK_INT < 33) {
                Toast.makeText(context, "Code copied", Toast.LENGTH_SHORT).show()
            }
        }
    }

    companion object {
        const val ACTION_COPY = "com.Zen.app.WIDGET_COPY_CODE"
        const val EXTRA_CODE = "whoosh_code"

        private fun launchIntent(context: Context, action: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                this.action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("widget_action", action)
            }
            // Use a unique requestCode per action so PendingIntents are not collapsed
            val code = if (action == "send") 10 else 11
            return PendingIntent.getActivity(
                context, code, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun updateWidget(context: Context, mgr: AppWidgetManager, widgetId: Int) {
            // Flutter's shared_preferences stores keys with the "flutter." prefix
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.short_code", null)
            val displayCode = if (!raw.isNullOrBlank() && raw.length == 6) {
                "${raw.substring(0, 3)} ${raw.substring(3)}"
            } else {
                "— — —"
            }

            val views = RemoteViews(context.packageName, R.layout.widget_whoosh)
            views.setTextViewText(R.id.widget_code, displayCode)
            views.setOnClickPendingIntent(R.id.widget_btn_send, launchIntent(context, "send"))
            views.setOnClickPendingIntent(R.id.widget_btn_qr, launchIntent(context, "qr"))

            val copyIntent = Intent(context, WhooshWidgetProvider::class.java).apply {
                action = ACTION_COPY
                putExtra(EXTRA_CODE, raw ?: "")
            }
            val copyPi = PendingIntent.getBroadcast(
                context, 12, copyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_copy, copyPi)

            mgr.updateAppWidget(widgetId, views)
        }

        /** Called from MainActivity to refresh all placed widgets after identity loads. */
        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, WhooshWidgetProvider::class.java))
            ids.forEach { updateWidget(context, mgr, it) }
        }
    }
}
