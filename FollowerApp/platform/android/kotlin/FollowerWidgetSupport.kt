package org.nightscout.trio_follower

import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Date

/**
 * Everything the three follower widgets share: reading the payload the Flutter
 * side published, colouring by the host's thresholds, and drawing the chart.
 *
 * Values arrive pre-formatted from `lib/services/widget_bridge.dart`, so nothing
 * here repeats the app's unit conversion or rounding.
 */
object FollowerWidgetSupport {

    /** Matches the iOS widget and Trio itself: older than six minutes is stale. */
    private const val STALE_AFTER_MS = 6 * 60 * 1000L

    const val CHART_WIDTH = 600
    const val CHART_HEIGHT = 180
    private const val CHART_PADDING = 12.0

    // Matches the in-app chart (Flutter's Colors.red / green / orange).
    val COLOR_LOW: Int = Color.parseColor("#F44336")
    val COLOR_IN_RANGE: Int = Color.parseColor("#4CAF50")
    val COLOR_HIGH: Int = Color.parseColor("#FF9800")
    val COLOR_SECONDARY: Int = Color.parseColor("#8E8E93")

    fun loadStatus(context: Context): JSONObject? {
        // home_widget writes into this preferences file on Android.
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("trio_follower_status", null) ?: return null
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }

    /** Opens the app when the widget is tapped. */
    fun applyLaunchIntent(context: Context, views: RemoteViews, viewId: Int) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        views.setOnClickPendingIntent(
            viewId,
            PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )
    }

    fun isStale(status: JSONObject): Boolean {
        val date = status.optLong("glucoseDate", 0L)
        if (date <= 0L) return true
        return System.currentTimeMillis() - date > STALE_AFTER_MS
    }

    fun glucoseColor(value: Double?, low: Double, high: Double, stale: Boolean): Int {
        if (stale || value == null) return COLOR_SECONDARY
        return when {
            value <= low -> COLOR_LOW
            value >= high -> COLOR_HIGH
            else -> COLOR_IN_RANGE
        }
    }

    /** A string field, falling back when the key is absent, null or empty. */
    fun optString(status: JSONObject, key: String, fallback: String): String {
        if (status.isNull(key)) return fallback
        val value = status.optString(key, fallback)
        return if (value.isEmpty()) fallback else value
    }

    /** The reading's time in the device's own 12/24 hour format. */
    fun formatTime(context: Context, millis: Long): String {
        if (millis <= 0L) return "--"
        return android.text.format.DateFormat.getTimeFormat(context).format(Date(millis))
    }

    /** Minutes since the host last looped, or null when it has never reported one. */
    fun loopAgeMinutes(status: JSONObject): Long? {
        val last = status.optLong("lastLoop", 0L)
        if (last <= 0L) return null
        return (System.currentTimeMillis() - last) / 60000
    }

    fun loopColor(minutes: Long?): Int = when {
        minutes == null -> COLOR_SECONDARY
        minutes <= 6 -> COLOR_IN_RANGE
        minutes <= 15 -> COLOR_HIGH
        else -> COLOR_LOW
    }

    /**
     * Readings as a scatter with the threshold lines, drawn into a bitmap because
     * RemoteViews cannot host a custom view.
     *
     * The window comes from the data rather than a fixed six hours: the host trims
     * readings to fit its push budget, and stretching two hours of points across a
     * six-hour axis would bunch them all into one corner.
     */
    fun drawChart(status: JSONObject, low: Double, high: Double): Bitmap? {
        val points = status.optJSONArray("chart") ?: return null
        if (points.length() == 0) return null

        val times = ArrayList<Long>()
        val values = ArrayList<Double>()
        for (index in 0 until points.length()) {
            val point = points.optJSONObject(index) ?: continue
            val time = point.optLong("t", 0L)
            if (time <= 0L) continue
            times.add(time)
            values.add(point.optDouble("v", 0.0))
        }
        if (values.isEmpty()) return null

        val newest = times.maxOrNull() ?: return null
        val oldest = times.minOrNull() ?: return null
        // Never squeeze below an hour, so a couple of fresh readings do not turn
        // into a meaningless full-width spread.
        val span = (newest - oldest).coerceIn(60 * 60 * 1000L, 6 * 60 * 60 * 1000L)
        val windowStart = newest - span

        val bitmap = Bitmap.createBitmap(CHART_WIDTH, CHART_HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        val minValue = minOf(values.minOrNull() ?: low, low)
        val maxValue = maxOf(values.maxOrNull() ?: high, high)
        val range = (maxValue - minValue).takeIf { it > 0 } ?: 1.0

        fun y(value: Double): Float =
            (CHART_HEIGHT - CHART_PADDING -
                ((value - minValue) / range) * (CHART_HEIGHT - 2 * CHART_PADDING)).toFloat()

        fun x(time: Long): Float =
            (((time - windowStart).toDouble() / span) * CHART_WIDTH).toFloat()

        paint.strokeWidth = 2f
        paint.pathEffect = DashPathEffect(floatArrayOf(8f, 8f), 0f)
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

    /** Whole hours the chart covers, for the "6h" caption. */
    fun chartWindowHours(status: JSONObject): Int {
        val points = status.optJSONArray("chart") ?: return 6
        var newest = Long.MIN_VALUE
        var oldest = Long.MAX_VALUE
        for (index in 0 until points.length()) {
            val time = points.optJSONObject(index)?.optLong("t", 0L) ?: 0L
            if (time <= 0L) continue
            newest = maxOf(newest, time)
            oldest = minOf(oldest, time)
        }
        if (newest == Long.MIN_VALUE || oldest == Long.MAX_VALUE) return 6
        val hours = Math.round((newest - oldest) / 3_600_000.0).toInt()
        return hours.coerceIn(1, 6)
    }
}
