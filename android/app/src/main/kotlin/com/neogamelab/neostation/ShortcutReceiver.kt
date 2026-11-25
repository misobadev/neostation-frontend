package com.neogamelab.neostation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Parcelable

/**
 * Legacy "add to home screen" broadcast.
 *
 * Launchers that predate `ShortcutManager.requestPinShortcut` ask the HOME app
 * to add a shortcut with this broadcast instead. Supporting it costs one
 * receiver and covers every launcher that never moved on.
 */
class ShortcutReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null || intent.action != ACTION_INSTALL_SHORTCUT) return
        val target = parcelableExtra<Intent>(intent, Intent.EXTRA_SHORTCUT_INTENT) ?: return
        val label = intent.getStringExtra(Intent.EXTRA_SHORTCUT_NAME)
        val component = target.component
        val packageName = component?.packageName ?: target.`package`
        PendingShortcuts.add(
            context,
            label,
            target.action,
            packageName,
            null,
            component?.flattenToShortString(),
            target.dataString,
            shortcutIcon(context, intent),
        )
    }

    /**
     * `EXTRA_SHORTCUT_ICON` is a Bitmap on the modern form and a
     * `ShortcutIconResource` on the ancient one; only the bitmap can be
     * rasterised here, and a missing icon is not fatal.
     */
    private fun shortcutIcon(context: Context, intent: Intent): Drawable? {
        val bitmap = parcelableExtra<Bitmap>(intent, Intent.EXTRA_SHORTCUT_ICON) ?: return null
        return BitmapDrawable(context.resources, bitmap)
    }

    private inline fun <reified T : Parcelable> parcelableExtra(
        intent: Intent,
        name: String,
    ): T? = try {
        @Suppress("DEPRECATION")
        intent.getParcelableExtra(name) as? T
    } catch (e: Exception) {
        null
    }

    companion object {
        const val ACTION_INSTALL_SHORTCUT = "com.android.launcher.action.INSTALL_SHORTCUT"
    }
}
