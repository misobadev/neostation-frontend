package com.neogamelab.neostation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/**
 * Resolves whether a libretro core is actually installed for a RetroArch
 * package.
 *
 * RetroArch keeps its cores in its own private `dataDir/cores/` directory,
 * which this app cannot read on a normal Android device. A plain `exists()`
 * therefore answers "no" even when the core is installed, so the filesystem
 * probe is only a fast path. When it cannot answer, this asks RetroArch's
 * exported InstalledCoresReceiver over the public broadcast contract:
 *
 *   query:  com.retroarch.QUERY_INSTALLED_CORES
 *   reply:  com.retroarch.INSTALLED_CORES_RESULT, extra CORES (String[])
 *
 * The receiver exists on RetroArch master (PR #18870) but not in releases up
 * to 1.22.x. When it is unavailable, times out or fails, the answer is null
 * ("unknown") and callers must fail open, exactly like ES-DE does.
 */
object RetroArchCoreChecker {
    private const val TAG = "RetroArchCore"
    private const val QUERY = "com.retroarch.QUERY_INSTALLED_CORES"
    private const val RESULT = "com.retroarch.INSTALLED_CORES_RESULT"
    private const val EXTRA_CORES = "CORES"

    /// How long to wait for RetroArch's reply. ES-DE uses 600 ms; a little
    /// slack keeps slow devices from failing open unnecessarily.
    private const val TIMEOUT_MS = 700L

    /// The installed-core list changes only when the user installs or removes
    /// a core, so a short cache avoids re-querying it for every emulator.
    private const val CACHE_TTL_MS = 10_000L

    /// After a timeout, don't make every row in the list wait again. A forced
    /// launch check bypasses this.
    private const val TIMEOUT_RETRY_MS = 30_000L

    private const val MAX_CORES = 4096
    private const val MAX_TOTAL_CHARS = 65_536

    private val coreNameRegex = Regex("""[A-Za-z0-9_+\-]+_libretro(?:_android)?\.so""")
    private val baseNameRegex = Regex("""[A-Za-z0-9_+\-]+""")

    private val lock = ReentrantLock()
    private val executor = Executors.newSingleThreadExecutor()
    private val cache = mutableMapOf<String, CachedCores>()
    private val unsupported = mutableSetOf<String>()
    private val timedOutAt = mutableMapOf<String, Long>()

    private data class CachedCores(val names: Set<String>, val at: Long)

    /**
     * Runs the check off the main thread and delivers a tri-state answer:
     * `true` installed, `false` confirmed absent, `null` could not determine.
     */
    fun check(
        context: Context,
        packageName: String,
        coreFilename: String,
        forceRefresh: Boolean,
        callback: (Boolean?) -> Unit,
    ) {
        val appContext = context.applicationContext
        executor.execute {
            val answer = try {
                checkBlocking(appContext, packageName, coreFilename, forceRefresh)
            } catch (error: Throwable) {
                Log.w(TAG, "Core check failed for $packageName/$coreFilename", error)
                null
            }
            Handler(Looper.getMainLooper()).post { callback(answer) }
        }
    }

    private fun checkBlocking(
        context: Context,
        packageName: String,
        coreFilename: String,
        forceRefresh: Boolean,
    ): Boolean? {
        if (packageName.isBlank() || coreFilename.isBlank()) return null
        val base = normalizeBase(coreFilename) ?: return null
        val coresDir = coresDirectory(context, packageName) ?: return null
        val rawName = coreFilename.substringAfterLast('/').trim()
        val candidates = linkedSetOf(
            "${base}_libretro_android.so",
            "${base}_libretro.so",
            rawName,
        )

        // Fast path: the directory is readable, so the filesystem is
        // authoritative. This is only possible outside RetroArch's sandbox.
        if (candidates.any { File(coresDir, it).isFile }) return true
        val dir = File(coresDir)
        if (dir.isDirectory && dir.canRead()) return false

        lock.lock()
        try {
            val now = SystemClock.elapsedRealtime()
            if (!forceRefresh) {
                cache[packageName]?.let { cached ->
                    if (now - cached.at <= CACHE_TTL_MS) {
                        return cached.names.any { normalizeBase(it) == base }
                    }
                }
                if (packageName in unsupported) return null
                val previousTimeout = timedOutAt[packageName]
                if (previousTimeout != null && now - previousTimeout < TIMEOUT_RETRY_MS) {
                    return null
                }
            }

            if (!hasReceiver(context, packageName)) {
                Log.w(
                    TAG,
                    "$packageName does not declare $QUERY; cannot verify core " +
                        "\"$coreFilename\". Update RetroArch to a build with " +
                        "InstalledCoresReceiver (2026-03 or newer).",
                )
                unsupported.add(packageName)
                return null
            }
            unsupported.remove(packageName)

            val names = queryInstalledCores(context, packageName)
            if (names == null) {
                Log.w(
                    TAG,
                    "No reply to $QUERY from $packageName within ${TIMEOUT_MS}ms; " +
                        "cannot verify core \"$coreFilename\".",
                )
                timedOutAt[packageName] = now
                return null
            }
            Log.i(
                TAG,
                "$packageName reports ${names.size} installed core(s); " +
                    "checking \"$coreFilename\".",
            )
            timedOutAt.remove(packageName)
            cache[packageName] = CachedCores(names, now)
            return names.any { normalizeBase(it) == base }
        } finally {
            lock.unlock()
        }
    }

    /** The basename RetroArch uses for [coreFilename], without `.so`/suffixes. */
    private fun normalizeBase(coreFilename: String): String? {
        val name = coreFilename.substringAfterLast('/').trim()
        if (name.isEmpty()) return null
        var base = if (name.endsWith(".so", ignoreCase = true)) {
            name.dropLast(3)
        } else {
            name
        }
        base = when {
            base.endsWith("_libretro_android", ignoreCase = true) ->
                base.dropLast("_libretro_android".length)
            base.endsWith("_libretro", ignoreCase = true) ->
                base.dropLast("_libretro".length)
            else -> base
        }
        return base.takeIf { it.isNotEmpty() && it.matches(baseNameRegex) }
    }

    private fun coresDirectory(context: Context, packageName: String): String? {
        return try {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            "${info.dataDir}/cores"
        } catch (error: PackageManager.NameNotFoundException) {
            null
        }
    }

    /**
     * Whether the installed package actually declares the query receiver.
     * Skipping the wait entirely on releases without it keeps launch latency
     * unchanged there.
     */
    private fun hasReceiver(context: Context, packageName: String): Boolean {
        return try {
            val intent = Intent(QUERY).setPackage(packageName)
            val receivers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.queryBroadcastReceivers(
                    intent,
                    PackageManager.ResolveInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.queryBroadcastReceivers(intent, 0)
            }
            receivers.isNotEmpty()
        } catch (error: Exception) {
            Log.w(TAG, "Could not query receiver for $packageName", error)
            false
        }
    }

    /**
     * Sends the query and waits for one reply. Returns null on timeout or a
     * malformed/spoofed reply; an empty set is a valid "no cores installed".
     */
    private fun queryInstalledCores(context: Context, packageName: String): Set<String>? {
        val latch = CountDownLatch(1)
        var answer: Set<String>? = null
        val thread = HandlerThread("neostation-core-query").apply { start() }
        val handler = Handler(thread.looper)
        var registered = false

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receivingContext: Context, intent: Intent) {
                if (intent.action != RESULT) return
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    val sender = sentFromPackage
                    if (sender != null && sender != packageName) return
                }
                val cores = intent.getStringArrayExtra(EXTRA_CORES)
                if (cores == null ||
                    cores.size > MAX_CORES ||
                    cores.any { it == null || it.length !in 1..128 || !it.matches(coreNameRegex) } ||
                    cores.sumOf { it.length } > MAX_TOTAL_CHARS
                ) {
                    return
                }
                answer = cores.toSet()
                latch.countDown()
            }
        }

        try {
            val filter = IntentFilter(RESULT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(
                    receiver,
                    filter,
                    null,
                    handler,
                    Context.RECEIVER_EXPORTED,
                )
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, filter, null, handler)
            }
            registered = true

            val query = Intent(QUERY)
                .setPackage(packageName)
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES or Intent.FLAG_RECEIVER_FOREGROUND)
            context.sendBroadcast(query)
            latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
            return answer
        } catch (error: Exception) {
            Log.w(TAG, "Core query failed for $packageName", error)
            return null
        } finally {
            if (registered) {
                try {
                    context.unregisterReceiver(receiver)
                } catch (_: IllegalArgumentException) {
                    // Already gone; nothing to release.
                }
            }
            thread.quitSafely()
        }
    }
}
