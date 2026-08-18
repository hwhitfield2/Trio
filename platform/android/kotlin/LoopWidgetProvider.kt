package org.nightscout.trio_follower

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Widget 3 of 3: loop and insulin.
 *
 * How long since the host last looped, insulin and carbs on board, where it
 * expects glucose to land, and any active override or temp target. No chart —
 * this is the widget for reassurance rather than the curve.
 */
class LoopWidgetProvider : AppWidgetProvider() {

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
        val views = RemoteViews(context.packageName, R.layout.loop_widget)
        FollowerWidgetSupport.applyLaunchIntent(context, views, R.id.loop_root)

        if (status == null) {
            views.setTextViewText(R.id.loop_age, "--")
            views.setTextViewText(R.id.loop_iob, "")
            views.setTextViewText(R.id.loop_cob, "")
            views.setTextViewText(R.id.loop_eventual, "")
            views.setTextViewText(R.id.loop_active, context.getString(R.string.widget_open_app))
            views.setTextColor(R.id.loop_age, FollowerWidgetSupport.COLOR_SECONDARY)
            return views
        }

        val minutes = FollowerWidgetSupport.loopAgeMinutes(status)
        views.setTextViewText(
            R.id.loop_age,
            if (minutes == null) {
                "--"
            } else if (minutes < 1) {
                context.getString(R.string.widget_loop_now)
            } else {
                context.getString(R.string.widget_loop_age, minutes)
            }
        )
        views.setTextColor(R.id.loop_age, FollowerWidgetSupport.loopColor(minutes))

        views.setTextViewText(
            R.id.loop_iob,
            "IOB " + FollowerWidgetSupport.optString(status, "iob", "--") + " U"
        )
        views.setTextViewText(
            R.id.loop_cob,
            "COB " + FollowerWidgetSupport.optString(status, "cob", "--") + " g"
        )
        views.setTextViewText(
            R.id.loop_eventual,
            "⇢ " + FollowerWidgetSupport.optString(status, "eventualBg", "--")
        )

        val override = FollowerWidgetSupport.optString(status, "overrideName", "")
        val tempTarget = FollowerWidgetSupport.optString(status, "tempTargetName", "")
        val active = listOf(override, tempTarget).firstOrNull { it.isNotEmpty() }
        views.setTextViewText(
            R.id.loop_active,
            active ?: context.getString(R.string.widget_no_adjustment)
        )

        return views
    }
}
