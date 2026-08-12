package org.nightscout.trio_follower

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/**
 * Creates one notification channel per alert sound.
 *
 * Android binds a sound to a channel when the channel is created and refuses to
 * change it afterwards, so "pick a sound" has to mean "pick a channel". The host
 * sends the channel id with each alert push; these are the channels it can name.
 *
 * Keep the ids in sync with `FollowerAlertSound.androidChannelId` on the host.
 */
object AlertChannels {

    /** (channel id, user-visible name, sound file in res/raw or null for silent) */
    private val CHANNELS = listOf(
        Triple("trio_alert_silent", "Trio alerts (silent)", null),
        Triple("trio_alert_system", "Trio alerts (default sound)", ""),
        Triple("trio_alert_gentle", "Trio alerts (gentle)", "alert_gentle"),
        Triple("trio_alert_standard", "Trio alerts (standard)", "alert_standard"),
        Triple("trio_alert_urgent", "Trio alerts (urgent)", "alert_urgent")
    )

    fun register(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return

        val attributes = AudioAttributes.Builder()
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .build()

        for ((id, name, sound) in CHANNELS) {
            val importance = if (sound == null) {
                NotificationManager.IMPORTANCE_DEFAULT
            } else {
                NotificationManager.IMPORTANCE_HIGH
            }
            val channel = NotificationChannel(id, name, importance)
            channel.description = "Glucose alerts pushed by the paired Trio host."
            when {
                sound == null -> channel.setSound(null, null)
                sound.isEmpty() -> Unit // leave the system default in place
                else -> channel.setSound(
                    Uri.parse("android.resource://${context.packageName}/raw/$sound"),
                    attributes
                )
            }
            manager.createNotificationChannel(channel)
        }
    }
}

/**
 * Registers the channels before the first push can arrive.
 *
 * A ContentProvider is created during application startup, ahead of any
 * activity and ahead of FCM delivering a notification — which matters because a
 * notification naming a channel that does not exist yet is dropped on Android 8
 * and later. Doing this from Dart would be too late for a cold-start push.
 */
class AlertChannelsInitializer : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.let { AlertChannels.register(it) }
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
