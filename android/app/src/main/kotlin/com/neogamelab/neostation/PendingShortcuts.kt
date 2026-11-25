package com.neogamelab.neostation

import android.content.Context
import android.content.pm.ShortcutInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Queue of shortcuts another launcher asked NeoStation to pin.
 *
 * A pin can arrive while NeoStation is dead, so the queue lives on disk and the
 * Dart side drains it when it next runs. Icons ride along as base64 PNG, which
 * keeps the queue a single file with no temp directory to leak or clean up.
 *
 * Everything here is best effort: a pin that cannot be recorded must not take
 * the launcher down with it.
 */
object PendingShortcuts {
    private const val FILE_NAME = "pending_shortcuts.json"
    private const val ICON_PX = 256
    private val lock = Any()

    /**
     * External app storage rather than `filesDir`: it is the same process
     * either way, and the queue is easier to inspect where it lives.
     */
    private fun file(context: Context) =
        File(context.getExternalFilesDir(null) ?: context.filesDir, FILE_NAME)

    /** Whether anything is queued, so a resume knows if it is worth asking. */
    fun hasPending(context: Context): Boolean = try {
        file(context).length() > 2L
    } catch (e: Exception) {
        false
    }

    /**
     * Records a pin request.
     *
     * [label] and [packageName] are required — without them the entry could not
     * be shown or launched. The rest is optional: a pinned shortcut arrives with
     * only a shortcut id, while the legacy broadcast arrives with an intent.
     */
    fun add(
        context: Context,
        label: String?,
        action: String?,
        packageName: String?,
        shortcutId: String?,
        component: String?,
        data: String?,
        icon: Drawable?,
    ) {
        if (label.isNullOrBlank() || packageName.isNullOrBlank()) return
        val entry = JSONObject().apply {
            put("label", label.take(120))
            put("action", action)
            put("package", packageName)
            if (!shortcutId.isNullOrEmpty()) put("shortcut", shortcutId)
            if (!component.isNullOrEmpty()) put("component", component)
            if (!data.isNullOrEmpty()) put("data", data)
            encodeIcon(icon)?.let { put("icon", it) }
        }
        synchronized(lock) {
            val target = file(context)
            val entries = read(target)
            entries.put(entry)
            write(target, entries)
        }
    }

    /**
     * Convenience for a [ShortcutInfo] and the icon resolved for it.
     *
     * The system hands a pinned shortcut back with its intent sanitised, so the
     * fields below are usually absent; the creator package and the shortcut id
     * are the parts that survive, and they are what an implicit launch needs.
     */
    fun add(context: Context, info: ShortcutInfo, icon: Drawable?) {
        val intent = info.intent
        add(
            context,
            info.shortLabel?.toString() ?: info.longLabel?.toString(),
            intent?.action,
            info.`package`,
            info.id,
            intent?.component?.flattenToShortString(),
            intent?.dataString,
            icon,
        )
    }

    /** Returns every queued entry and empties the queue. */
    fun consume(context: Context): List<Map<String, Any?>> {
        synchronized(lock) {
            val target = file(context)
            val entries = read(target)
            target.delete()
            // org.json's JSONArray is not Iterable, so walk it by index.
            val drained = ArrayList<Map<String, Any?>>(entries.length())
            for (index in 0 until entries.length()) {
                val obj = entries.optJSONObject(index) ?: continue
                val label = obj.optString("label").takeIf { it.isNotEmpty() } ?: continue
                val packageName = obj.optString("package").takeIf { it.isNotEmpty() } ?: continue
                val entry = HashMap<String, Any?>(5)
                entry["label"] = label
                entry["package"] = packageName
                obj.optString("action").takeIf { it.isNotEmpty() }?.let { entry["action"] = it }
                obj.optString("shortcut").takeIf { it.isNotEmpty() }?.let { entry["shortcut"] = it }
                obj.optString("component").takeIf { it.isNotEmpty() }?.let { entry["component"] = it }
                obj.optString("data").takeIf { it.isNotEmpty() }?.let { entry["data"] = it }
                obj.optString("icon").takeIf { it.isNotEmpty() }?.let { entry["icon"] = it }
                drained.add(entry)
            }
            return drained
        }
    }

    /**
     * Rasterises [icon] to a PNG the Dart side can write straight to the media
     * folder. Sized like the app-icon cache, since the same views draw both.
     */
    private fun encodeIcon(icon: Drawable?): String? {
        if (icon == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return try {
            val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            icon.setBounds(0, 0, ICON_PX, ICON_PX)
            icon.draw(canvas)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }

    private fun read(target: File): JSONArray = try {
        if (target.exists()) JSONArray(target.readText()) else JSONArray()
    } catch (e: Exception) {
        JSONArray()
    }

    private fun write(target: File, entries: JSONArray) {
        try {
            val temporary = File(target.parentFile, "$FILE_NAME.tmp")
            temporary.writeText(entries.toString())
            if (!temporary.renameTo(target)) {
                target.writeText(entries.toString())
                temporary.delete()
            }
        } catch (e: Exception) {
            // Best effort: the pin is lost, the launcher is not.
        }
    }
}
