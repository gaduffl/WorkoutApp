package com.morningcoach.morningcoach

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Posts "MorningCoach was updated — tap to open" once the new build has replaced
 * the old one, after an install that closed the app in front of the person.
 *
 * Nothing can reopen the app by itself: the process that installed is gone,
 * and a process in the background may not start an activity. What Android does
 * do is start the new build for `MY_PACKAGE_REPLACED`, so the old build leaves
 * the text — in the person's language, which only Dart knew — where this
 * receiver finds it. No text left behind means the install was not one that
 * closed the app in front of anyone, and nothing is posted.
 */
class UpdatedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val notice = recall(context) ?: return
        forget(context)
        // Already back in the app: there is nothing to bring them back to.
        if (MainActivity.visible) return
        // Replaced by something other than the build being installed — a
        // downgrade, another installer — so not this update.
        if (installedVersionCode(context) < notice.versionCode) return
        try {
            post(context, notice)
        } catch (ignored: Exception) {
            // Notifications switched off; the update happened regardless.
        }
    }

    data class Notice(
        val channelName: String,
        val title: String,
        val body: String,
        val versionCode: Long,
    )

    companion object {
        // Tagged, because reminder ids are hashes that could land on any number.
        private const val NOTIFICATION_TAG = "app_updated"
        private const val NOTIFICATION_ID = 1

        // Silent and prominent are fixed when the channel is first created;
        // changing either needs a new id, never an edit to this one.
        private const val CHANNEL_ID = "app_updated"

        private const val PREFS = "morningcoach_update_notice"
        private const val KEY_CHANNEL = "channel"
        private const val KEY_TITLE = "title"
        private const val KEY_BODY = "body"
        private const val KEY_VERSION_CODE = "version_code"

        /**
         * Left by the installing build before it commits. Written synchronously:
         * the commit can end this process before an asynchronous write lands.
         */
        @SuppressLint("ApplySharedPref")
        fun remember(context: Context, notice: Notice?) {
            if (notice == null) {
                forget(context)
                return
            }
            prefs(context).edit()
                .putString(KEY_CHANNEL, notice.channelName)
                .putString(KEY_TITLE, notice.title)
                .putString(KEY_BODY, notice.body)
                .putLong(KEY_VERSION_CODE, notice.versionCode)
                .commit()
        }

        /** An install that failed or was turned down must not announce itself later. */
        @SuppressLint("ApplySharedPref")
        fun forget(context: Context) {
            prefs(context).edit().clear().commit()
        }

        /** The person is back in the app; the way back is no longer needed. */
        fun dismiss(context: Context) {
            try {
                manager(context).cancel(NOTIFICATION_TAG, NOTIFICATION_ID)
            } catch (ignored: Exception) {
                // Nothing to dismiss.
            }
        }

        private fun recall(context: Context): Notice? {
            val prefs = prefs(context)
            val title = prefs.getString(KEY_TITLE, null) ?: return null
            return Notice(
                channelName = prefs.getString(KEY_CHANNEL, null) ?: title,
                title = title,
                body = prefs.getString(KEY_BODY, null) ?: "",
                versionCode = prefs.getLong(KEY_VERSION_CODE, 0L),
            )
        }

        private fun prefs(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun installedVersionCode(context: Context): Long {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
        }

        private fun post(context: Context, notice: Notice) {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return
            val tap = PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val manager = manager(context)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // It follows the app closing in front of the person, so it should
                // be seen at once (a heads-up) but never heard. Recreating the
                // channel only refreshes its name, which follows their language.
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    notice.channelName,
                    NotificationManager.IMPORTANCE_HIGH,
                )
                channel.setSound(null, null)
                channel.enableVibration(false)
                manager.createNotificationChannel(channel)
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(notice.title)
                .setContentText(notice.body)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build()
            manager.notify(NOTIFICATION_TAG, NOTIFICATION_ID, notification)
        }
    }
}

