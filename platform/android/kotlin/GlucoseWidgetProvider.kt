package org.nightscout.trio_follower

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Widget 1 of 3: glucose now.
 *
 * The reading, trend and delta with insulin and carbs on board underneath, plus
 * the chart. Answers "what is it right now".
 */
class GlucoseWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val status = FollowerWidgetSupport.loadStatus(context)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context, status))
        }
    }

    private fun buildViews(context: Context, status: JSONObject?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.glucose_widget)
        FollowerWidgetSupport.applyLaunchIntent(context, views, R.id.widget_root)

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
        val stale = FollowerWidgetSupport.isStale(status)
        val glucoseColor = FollowerWidgetSupport.glucoseColor(bg.toDoubleOrNull(), low, high, stale)

        views.setTextViewText(R.id.widget_bg, bg)
        views.setTextColor(R.id.widget_bg, glucoseColor)
        views.setTextViewText(R.id.widget_direction, status.optString("direction", ""))
        views.setTextColor(R.id.widget_direction, glucoseColor)
        views.setTextViewText(R.id.widget_change, status.optString("change", ""))

        views.setTextViewText(
            R.id.widget_iob,
            "IOB " + FollowerWidgetSupport.optString(status, "iob", "--")
        )
        views.setTextViewText(
            R.id.widget_cob,
            "COB " + FollowerWidgetSupport.optString(status, "cob", "--")
        )
        views.setTextViewText(
            R.id.widget_updated,
            FollowerWidgetSupport.formatTime(context, status.optLong("glucoseDate", 0L))
        )

        views.setImageViewBitmap(
            R.id.widget_chart,
            FollowerWidgetSupport.drawChart(status, low, high)
        )
        return views
    }
}
