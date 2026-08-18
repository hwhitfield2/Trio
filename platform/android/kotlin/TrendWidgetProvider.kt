package org.nightscout.trio_follower

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Widget 2 of 3: trend and range.
 *
 * The chart gets the whole widget, with the share of readings low / in range /
 * high underneath. Answers "how has it been going", not "what is it now".
 */
class TrendWidgetProvider : AppWidgetProvider() {

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
        val views = RemoteViews(context.packageName, R.layout.trend_widget)
        FollowerWidgetSupport.applyLaunchIntent(context, views, R.id.trend_root)

        if (status == null) {
            views.setTextViewText(R.id.trend_bg, "--")
            views.setTextViewText(R.id.trend_direction, "")
            views.setTextViewText(R.id.trend_updated, "")
            views.setTextViewText(R.id.trend_stats, context.getString(R.string.widget_open_app))
            views.setImageViewBitmap(R.id.trend_chart, null)
            return views
        }

        val low = status.optDouble("low", 70.0)
        val high = status.optDouble("high", 180.0)
        val bg = status.optString("bg", "--")
        val stale = FollowerWidgetSupport.isStale(status)
        val colorRanges = FollowerWidgetSupport.ColorRanges.from(status)
        val glucoseColor =
            FollowerWidgetSupport.glucoseColor(bg.toDoubleOrNull(), low, high, stale, colorRanges)

        views.setTextViewText(R.id.trend_bg, bg)
        views.setTextColor(R.id.trend_bg, glucoseColor)
        views.setTextViewText(R.id.trend_direction, status.optString("direction", ""))
        views.setTextColor(R.id.trend_direction, glucoseColor)
        views.setTextViewText(
            R.id.trend_updated,
            FollowerWidgetSupport.formatTime(context, status.optLong("glucoseDate", 0L))
        )
        views.setImageViewBitmap(
            R.id.trend_chart,
            FollowerWidgetSupport.drawChart(status, low, high, colorRanges)
        )

        val hours = FollowerWidgetSupport.chartWindowHours(status)
        val stats = status.optJSONObject("stats")
        if (stats == null) {
            views.setTextViewText(
                R.id.trend_stats,
                status.optString("units", "") + " · " + hours + "h"
            )
        } else {
            val inRange = stats.optInt("in_range", 0)
            val lowPct = stats.optInt("low", 0)
            val highPct = stats.optInt("high", 0)
            views.setTextViewText(
                R.id.trend_stats,
                context.getString(R.string.widget_range_summary, inRange, lowPct, highPct, hours)
            )
        }

        return views
    }
}
