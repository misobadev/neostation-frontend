package com.hcoderlee.subscreen.sub_screen

import android.util.DisplayMetrics
import android.view.Display
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

const val methodChannelName = "com.hcoderlee.subscreen.sub_screen/methods"
const val sharedStateChannelName = "com.hcoderlee.subscreen.sub_screen/shared_state"

class SubScreenPlugin : FlutterPlugin {
    companion object {
        private val methodHandlerDelegator = PluginMethodHandlerDelegator()
        val multiDisplayCallback: MultiDisplayCallback get() = methodHandlerDelegator
    }

    private var handlerId: Int? = null
    private lateinit var sharedStatsChannel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        if (handlerId != null) {
            methodHandlerDelegator.dispose(handlerId!!)
        }
        handlerId = methodHandlerDelegator.createHandler(flutterPluginBinding)
        sharedStatsChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            sharedStateChannelName
        )
        initSharedStatsChannel()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (handlerId != null) {
            methodHandlerDelegator.dispose(handlerId!!)
        }
        SharedStateManager.removeOnStateChangeListener(::onSharedStatsChange)
    }

    @Suppress("UNCHECKED_CAST")
    private fun initSharedStatsChannel() {
        sharedStatsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAllState" -> {
                    val allState = SharedStateManager.getAllState()
                    result.success(allState)
                }

                "updateState" -> {
                    val data = call.arguments as Map<*, *>
                    val type = data["type"] as String
                    val state = data["state"] as Map<String, Any>?
                    SharedStateManager.updateState(type, state)
                    result.success(null)
                }

                "getState" -> {
                    val data = call.arguments as Map<*, *>
                    val type = data["type"] as String
                    val state = SharedStateManager.getState(type)
                    result.success(state)
                }

                "clearState" -> {
                    val data = call.arguments as Map<*, *>
                    val type = data["type"] as String
                    SharedStateManager.removeState(type)
                    result.success(null)
                }

                else -> {
                    throw Exception("Unimplemented method: ${call.method}")
                }
            }
        }

        SharedStateManager.addOnStateChangeListener(::onSharedStatsChange)
    }

    private fun onSharedStatsChange(type: String, state: SharedState) {
        sharedStatsChannel.invokeMethod(
            "onStateChanged",
            mapOf("type" to type, "data" to state)
        )
    }
}

interface MultiDisplayCallback {
    fun onDisplayAdded(display: Display)
    fun onDisplayChange(display: Display)
    fun onDisplayRemoved(displayId: Int)
}

class PluginMethodHandler(
    flutterPluginBinding: FlutterPlugin.FlutterPluginBinding
) : MethodCallHandler, MultiDisplayCallback {
    private val channel: MethodChannel =
        MethodChannel(flutterPluginBinding.binaryMessenger, methodChannelName)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getDisplays" -> {
                result.success(getDisplaysInfo())
            }

            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onDisplayAdded(display: Display) {
        invokeMethod(
            "onDisplayAdded", mapOf(
                "display" to getDisplayInfo(display)
            )
        )
    }

    override fun onDisplayChange(display: Display) {
        invokeMethod(
            "onDisplayChanged", mapOf(
                "display" to getDisplayInfo(display)
            )
        )
    }

    override fun onDisplayRemoved(displayId: Int) {
        invokeMethod(
            "onDisplayRemoved", mapOf(
                "displayId" to displayId
            )
        )
    }

    @Suppress("DEPRECATION")
    private fun getDisplayInfo(display: Display): Map<String, Any> {
        val metrics = DisplayMetrics()
        display.getMetrics(metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.density
        val refreshRate = display.refreshRate
        return mapOf(
            "id" to display.displayId,
            "name" to display.name,
            "width" to width,
            "height" to height,
            "refreshRate" to refreshRate,
            "density" to density,
            "isDefault" to display.isDefault()
        )
    }

    private fun getDisplaysInfo(): Map<String, Any> {
        return mapOf(
            "displays" to MultiDisplayHandler.displays.map(::getDisplayInfo)
        )
    }

    private fun invokeMethod(method: String, params: Any?) {
        channel.invokeMethod(method, params)
    }
}

class PluginMethodHandlerDelegator : MultiDisplayCallback {
    companion object {
        private var latestId = 0
        private val handlers = mutableMapOf<Int, PluginMethodHandler>()
    }

    fun createHandler(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding): Int {
        val id = latestId++
        val handler = PluginMethodHandler(flutterPluginBinding)
        handlers.put(id, handler)
        return id
    }

    fun dispose(id: Int) {
        val handler = handlers.remove(id)
        handler?.dispose()
    }

    override fun onDisplayAdded(display: Display) {
        handlers.values.forEach { it.onDisplayAdded(display) }
    }

    override fun onDisplayChange(display: Display) {
        handlers.values.forEach { it.onDisplayChange(display) }
    }

    override fun onDisplayRemoved(displayId: Int) {
        handlers.values.forEach { it.onDisplayRemoved(displayId) }
    }
}