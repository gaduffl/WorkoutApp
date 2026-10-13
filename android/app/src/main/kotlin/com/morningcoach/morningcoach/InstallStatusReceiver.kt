package com.morningcoach.morningcoach

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/**
 * Receives the outcome of a committed install session.
 *
 * `STATUS_PENDING_USER_ACTION` carries the system's own confirmation screen as
 * an extra intent; this receiver is the one that has to start it — unless the
 * install was unattended, when it is declined instead. Everything else is
 * reported to Dart when the engine is still attached. A successful update
 * replaces this process, so success usually has no listener left to tell —
 * which is why the Dart side treats "no news" after a commit as normal.
 */
class InstallStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                if (intent.getBooleanExtra(EXTRA_UNATTENDED, false)) {
                    // Nobody is waiting on this install, so a system sheet
                    // must not appear over whatever they are doing now — and
                    // from the background Android would block it anyway. The
                    // session is given up; the app offers the update with a
                    // button instead.
                    abandon(context, intent)
                    UpdatedReceiver.forget(context)
                    listener?.invoke("confirmationRequired", null)
                    return
                }
                val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                }
                if (confirmation == null) {
                    listener?.invoke("failed", "The installer sent no confirmation screen.")
                    return
                }
                confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(confirmation)
                listener?.invoke("awaitingConfirmation", null)
            }
            PackageInstaller.STATUS_SUCCESS -> listener?.invoke("success", null)
            // The person backed out of the system sheet — not an error.
            PackageInstaller.STATUS_FAILURE_ABORTED -> {
                UpdatedReceiver.forget(context)
                listener?.invoke("cancelled", message)
            }
            else -> {
                UpdatedReceiver.forget(context)
                listener?.invoke("failed", message ?: "Install failed (status $status).")
            }
        }
    }

    private fun abandon(context: Context, intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (sessionId == -1) return
        try {
            context.packageManager.packageInstaller.abandonSession(sessionId)
        } catch (ignored: Exception) {
            // Already gone; the next install abandons leftovers in any case.
        }
    }

    companion object {
        const val ACTION = "com.morningcoach.morningcoach.INSTALL_STATUS"

        /**
         * Set by [ApkUpdater] when auto-update committed the session rather
         * than a tap, so a confirmation Android still wants is not forced on
         * screen.
         */
        const val EXTRA_UNATTENDED = "com.morningcoach.morningcoach.UNATTENDED"

        /** Set by [ApkUpdater] while a Flutter engine is attached. */
        @Volatile
        var listener: ((String, String?) -> Unit)? = null
    }
}

