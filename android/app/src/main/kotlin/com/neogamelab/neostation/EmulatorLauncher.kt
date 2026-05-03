package com.neogamelab.neostation

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import io.flutter.plugin.common.MethodChannel

object EmulatorLauncher {

    fun launchGenericIntent(
        context: Context,
        packageName: String,
        activityName: String?,
        action: String?,
        category: String?,
        data: String?,
        type: String?,
        extras: List<Map<String, Any>>?,
        activityFlags: List<String>,
        result: MethodChannel.Result
    ) {
        try {
            val intent = Intent()
            if (activityName != null) {
                intent.component = ComponentName(packageName, activityName)
            } else {
                intent.setPackage(packageName)
            }
            intent.action = action ?: Intent.ACTION_MAIN

            if (category != null) {
                intent.addCategory(category)
            } else if (action == null || action == Intent.ACTION_MAIN) {
                intent.addCategory(Intent.CATEGORY_LAUNCHER)
            }

            var uriData: Uri? = null
            if (data != null) {
                uriData = if (!data.contains("://") && data.startsWith("/")) {
                    Uri.parse("file://$data")
                } else {
                    Uri.parse(data)
                }
            }

            if (uriData != null && type != null) {
                intent.setDataAndType(uriData, type)
            } else if (uriData != null) {
                intent.data = uriData
            } else if (type != null) {
                intent.type = type
            }

            // FLAG_ACTIVITY_NEW_TASK is always required when launching from a non-Activity context.
            // All other flags come from the JSON config via --activity-* args.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activityFlags.forEach { flag -> flagStringToIntent(flag)?.let { intent.addFlags(it) } }

            // Resolve SAF content:// to real file path for RetroArch (needs filesystem access, not content URIs)
            var resolvedRomPath: String? = null
            if (packageName.startsWith("com.retroarch") && extras != null) {
                for (extra in extras) {
                    val key = extra["key"] as? String
                    val value = extra["value"]
                    if (key == "ROM" && value != null) {
                        val romPath = value.toString()
                        if (romPath.startsWith("content://")) {
                            resolvedRomPath = resolveSafUriToPath(context, Uri.parse(romPath))
                        }
                    }
                }
            }

            // Set extras
            if (extras != null) {
                for (extra in extras) {
                    val key = extra["key"] as? String ?: continue
                    val value = extra["value"] ?: continue
                    val valueType = extra["type"] as? String ?: continue
                    var finalValue = value.toString()

                    if (packageName.startsWith("com.retroarch")) {
                        when (key) {
                            "ROM" -> {
                                intent.putExtra(key, resolvedRomPath ?: finalValue)
                                continue
                            }
                            "LIBRETRO" -> if (!finalValue.startsWith("/")) {
                                val libretroDir = getDefaultLibretroDirectory(packageName)
                                val base = finalValue
                                    .removeSuffix("_libretro_android.so")
                                    .removeSuffix("_libretro.so")
                                intent.putExtra(key, "$libretroDir${base}_libretro_android.so")
                                continue
                            }
                        }
                    }

                    when (valueType) {
                        "string" -> intent.putExtra(key, finalValue)
                        "bool" -> intent.putExtra(key, finalValue.toBoolean())
                        "int" -> intent.putExtra(key, finalValue.toIntOrNull() ?: 0)
                        "long" -> intent.putExtra(key, finalValue.toLongOrNull() ?: 0L)
                        "float" -> intent.putExtra(key, finalValue.toFloatOrNull() ?: 0.0f)
                        "uri" -> intent.putExtra(key, Uri.parse(finalValue))
                        "string_array" -> intent.putExtra(
                            key, finalValue.split(",").map { it.trim() }.toTypedArray()
                        )
                    }
                }
            }

            // Generic SAF permission grant: any content:// URI in data or extras gets
            // ClipData + permissions so Android propagates the grant correctly.
            // PREFIX is included so apps (e.g. aPS3e) that access URI subtrees also work.
            val primaryContentUri: Uri? = when {
                uriData?.scheme == "content" -> uriData
                else -> extras?.firstOrNull { extra ->
                    extra["value"]?.toString()?.startsWith("content://") == true
                }?.let { Uri.parse(it["value"].toString()) }
            }
            if (primaryContentUri != null) {
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                intent.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                intent.addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                if (intent.clipData == null) {
                    intent.clipData = ClipData.newRawUri("ROM", primaryContentUri)
                }
            }

            // RetroArch: ensure CONFIGFILE; if ROM couldn't resolve to real path, grant content URI permissions
            if (packageName.startsWith("com.retroarch")) {
                if (!intent.hasExtra("CONFIGFILE")) {
                    intent.putExtra(
                        "CONFIGFILE",
                        "/storage/emulated/0/Android/data/$packageName/files/retroarch.cfg"
                    )
                }
                if (resolvedRomPath == null && extras != null) {
                    for (extra in extras) {
                        if (extra["key"] == "ROM") {
                            val romVal = extra["value"]?.toString() ?: continue
                            if (romVal.startsWith("content://")) {
                                val romUri = Uri.parse(romVal)
                                intent.addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                )
                                intent.clipData = ClipData.newRawUri("ROM", romUri)
                            }
                        }
                    }
                }
            }

            // StrictMode: allow file:// URIs in intent data for legacy emulators that need them
            try {
                val m = android.os.StrictMode::class.java.getMethod("disableDeathOnFileUriExposure")
                m.invoke(null)
            } catch (e: Exception) { }

            // Don't use resolveActivity — returns null on Android 11+ for valid apps due to
            // package visibility restrictions. Catch ActivityNotFoundException instead.
            context.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("ACTIVITY_NOT_FOUND", "Emulator not installed or activity missing: $packageName", null)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Permission denied launching $packageName: ${e.message}", null)
        } catch (e: Exception) {
            e.printStackTrace()
            result.error("LAUNCH_FAILED", e.message, e.toString())
        }
    }

    private fun flagStringToIntent(flag: String): Int? = when (flag) {
        "clear-task" -> Intent.FLAG_ACTIVITY_CLEAR_TASK
        "clear-top" -> Intent.FLAG_ACTIVITY_CLEAR_TOP
        "no-animation" -> Intent.FLAG_ACTIVITY_NO_ANIMATION
        "no-history" -> Intent.FLAG_ACTIVITY_NO_HISTORY
        "single-top" -> Intent.FLAG_ACTIVITY_SINGLE_TOP
        "reorder-to-front" -> Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        "reset-task-if-needed" -> Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        "brought-to-front" -> Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT
        else -> null
    }

    private fun resolveSafUriToPath(context: Context, uri: Uri): String? {
        try {
            if (isExternalStorageDocument(uri)) {
                var docId = android.provider.DocumentsContract.getDocumentId(uri)
                if (docId.contains("%3A") || docId.contains("%3a")) {
                    docId = Uri.decode(docId)
                }
                val split = docId.split(":").toTypedArray()
                if (split.size < 2) return null
                val type = split[0]
                val path = split[1]
                return if ("primary".equals(type, ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().toString() + "/" + path
                } else {
                    "/storage/$type/$path"
                }
            }
        } catch (e: Exception) {
            println("Error resolving URI to path: $e")
        }
        return null
    }

    private fun getDefaultLibretroDirectory(retroArchPackage: String): String {
        return "/data/user/0/$retroArchPackage/cores/"
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean {
        return "com.android.externalstorage.documents" == uri.authority
    }
}
