package org.nightscout.trio_follower

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home screen widget showing the status the paired Trio host last pushed.
 *
 * Every displayed value is formatted by the Flutter side (see
 * `lib/services/widget_bridge.dart`) and handed over as one JSON payload, so
 * this provider only lays out strings and draws the chart.
 */
class GlucoseWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val status = loadStatus(context)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context, status))
        }
    }

    private fun loadStatus(context: Context): JSONObject? {
        // home_widget writes into this preferences file on Android.
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("trio_follower_status", null) ?: return null
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }

    private fun buildViews(context: Context, status: JSONObject?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.glucose_widget)

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) {
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        if (status == null) {
            views.setTextViewText(R.id.widget_bg, "--")
            views.setTextViewText(R.id.widget_direction, "")
            views.setTextViewText(R.id.widget_change, "")
            views.setTextViewText(R.id.widget_iob, context.getString(R.string.widget_open_app))
            views.setTextViewText(R.id.widget_cob, "")
            views.setTextViewText(R.id.widget_updated, "")
            views.setImageViewBitmap(R.id.widget_chart, null)
            return views
        }

        val low = status.optDouble("low", 70.0)
        val high = status.optDouble("high", 180.0)
        val bg = status.optString("bg", "--")
        val stale = isStale(status)

        views.setTextViewText(R.id.widget_bg, bg)
        views.setTextColor(R.id.widget_bg, glucoseColor(bg.toDoubleOrNull(), low, high, stale))
        views.setTextViewText(R.id.widget_direction, status.optString("direction", ""))
        views.setTextColor(
            R.id.widget_direction,
            glucoseColor(bg.toDoubleOrNull(), low, high, stale)
        )
        views.setTextViewText(R.id.widget_change, status.optString("change", ""))

        views.setTextViewText(R.id.widget_iob, "IOB " + optString(status, "iob", "--"))
        views.setTextViewText(R.id.widget_cob, "COB " + optString(status, "cob", "--"))
        views.setTextViewText(
            R.id.widget_updated,
            formatTime(context, status.optLong("glucoseDate", 0L))
        )

        views.setImageViewBitmap(R.id.widget_chart, drawChart(status, low, high))
        return views
    }

    /** Mirrors the iOS widget and Trio itself: older than six minutes is stale. */
    private fun isStale(status: JSONObject): Boolean {
        val date = status.optLong("glucoseDate", 0L)
        if (date <= 0L) return true
        return System.currentTimeMillis() - date > 6 * 60 * 1000
    }

    private fun glucoseColor(value: Double?, low: Double, high: Double, stale: Boolean): Int {
        if (stale || value == null) return COLOR_SECONDARY
        return when {
            value <= low -> COLOR_LOW
            value >= high -> COLOR_HIGH
            else -> COLOR_IN_RANGE
        }
    }

    private fun optString(status: JSONObject, key: String, fallback: String): String {
        if (status.isNull(key)) return fallback
        val value = status.optString(key, fallback)
        return if (value.isEmpty()) fallback else value
    }

    /** The reading's time in the device's own 12/24 hour format. */
    private fun formatTime(context: Context, millis: Long): String {
        if (millis <= 0L) return "--"
        return android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(millis))
    }

    /**
     * Six hours of readings as a simple scatter, coloured by the host's own
     * thresholds. RemoteViews cannot host a custom view, so the chart is drawn
     * into a bitmap.
     */
    private fun drawChart(status: JSONObject, low: Double, high: Double): Bitmap? {
        val points = status.optJSONArray("chart") ?: return null
        if (points.length() == 0) return null

        val now = System.currentTimeMillis()
        val windowStart = now - 6 * 60 * 60 * 1000

        val times = ArrayList<Long>()
        val values = ArrayList<Double>()
        for (index in 0 until points.length()) {
            val point = points.optJSONObject(index) ?: continue
            val time = point.optLong("t", 0L)
            if (time < windowStart) continue
            times.add(time)
            values.add(point.optDouble("v", 0.0))
        }
        if (values.isEmpty()) return null

        val bitmap = Bitmap.createBitmap(CHART_WIDTH, CHART_HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        val minValue = minOf(values.minOrNull() ?: low, low)
        val maxValue = maxOf(values.maxOrNull() ?: high, high)
        val span = (maxValue - minValue).takeIf { it > 0 } ?: 1.0

        fun y(value: Double): Float =
            (CHART_HEIGHT - CHART_PADDING -
                ((value - minValue) / span) * (CHART_HEIGHT - 2 * CHART_PADDING)).toFloat()

        fun x(time: Long): Float =
            (((time - windowStart).toDouble() / (now - windowStart)) * CHART_WIDTH).toFloat()

        paint.strokeWidth = 2f
        paint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(8f, 8f), 0f)
        paint.color = COLOR_HIGH
        canvas.drawLine(0f, y(high), CHART_WIDTH.toFloat(), y(high), paint)
        paint.color = COLOR_LOW
        canvas.drawLine(0f, y(low), CHART_WIDTH.toFloat(), y(low), paint)
        paint.pathEffect = null

        for (index in values.indices) {
            paint.color = glucoseColor(values[index], low, high, false)
            canvas.drawCircle(x(times[index]), y(values[index]), 4f, paint)
        }

        return bitmap
    }

    private companion object {
        const val CHART_WIDTH = 600
        const val CHART_HEIGHT = 180
        const val CHART_PADDING = 12.0

        // Matches the in-app chart (Flutter's Colors.red / green / orange).
        val COLOR_LOW = Color.parseColor("#F44336")
        val COLOR_IN_RANGE = Color.parseColor("#4CAF50")
        val COLOR_HIGH = Color.parseColor("#FF9800")
        val COLOR_SECONDARY = Color.parseColor("#8E8E93")
    }
}
