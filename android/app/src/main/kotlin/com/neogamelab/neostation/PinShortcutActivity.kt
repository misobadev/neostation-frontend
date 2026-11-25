package com.neogamelab.neostation

import android.app.Activity
import android.content.Intent
import android.content.pm.LauncherApps
import android.os.Build
import android.os.Bundle

/**
 * Receives a launcher's pin request and hands it to [PendingShortcuts].
 *
 * `ShortcutManager.requestPinShortcut` resolves the default HOME app's
 * `android.content.pm.action.CONFIRM_PIN_SHORTCUT` activity and starts it with
 * the [LauncherApps.PinItemRequest] in the intent. Declaring that filter is what
 * makes "Add to Home Screen" reach NeoStation at all — `LauncherApps.Callback`
 * carries no pin callback on current SDKs. DroidDeck declares the same filter
 * for the same reason.
 *
 * The activity is invisible: it accepts, records, opens the launcher and
 * finishes.
 */
class PinShortcutActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            acceptPinRequest()
        }
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
        finish()
    }

    private fun acceptPinRequest() {
        val launcherApps = getSystemService(LauncherApps::class.java) ?: return
        val request = try {
            launcherApps.getPinItemRequest(intent)
        } catch (e: Exception) {
            null
        } ?: return
        // Accepting is what tells the requesting launcher the pin landed; its
        // own confirmation toast keys on it.
        try {
            request.accept(null)
        } catch (e: Exception) {
            // Recorded anyway: the row is what the user asked for, and a failed
            // acknowledgement only costs the requester its toast.
        }
        val info = request.shortcutInfo ?: return
        val icon = try {
            launcherApps.getShortcutIconDrawable(info, resources.displayMetrics.densityDpi)
        } catch (e: Exception) {
            null
        }
        PendingShortcuts.add(this, info, icon)
    }
}
