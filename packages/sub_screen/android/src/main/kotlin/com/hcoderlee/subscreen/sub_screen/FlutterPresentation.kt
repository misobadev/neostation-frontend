package com.hcoderlee.subscreen.sub_screen

import android.app.Presentation
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroupCache
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint

open class FlutterPresentation(
    context: Context,
    display: Display,
    val entryPointFun: String
) : Presentation(context, display) {

    companion object {
        private const val TAG = "MultiDisplay"
    }

    private lateinit var flutterEngine: FlutterEngine
    private lateinit var flutterView: FlutterView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (getRenderMode() == RenderMode.surface) {
            val flutterSurfaceView = FlutterSurfaceView(
                context, getTransparencyMode() == TransparencyMode.transparent
            )
            flutterView = FlutterView(context, flutterSurfaceView)
        } else {
            val flutterTextureView = FlutterTextureView(context)
            flutterTextureView.isOpaque = getTransparencyMode() == TransparencyMode.opaque
            flutterView = FlutterView(context, flutterTextureView);
        }
        flutterView.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        setContentView(flutterView)

        val engineGroup =
            FlutterEngineGroupCache.getInstance().get(FlutterEngineHelper.ENGINE_GROUP_ID)
        val entryPoint = DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            entryPointFun
        )
        flutterEngine = engineGroup!!.createAndRunEngine(context, entryPoint)
        flutterView.attachToFlutterEngine(flutterEngine)

        // Make sure flutter view has focus at beginning, flutter framework will not transfer keyboard
        // event when flutter view is not focused
        flutterView.requestFocus()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
    }

    override fun show() {
        super.show()
        flutterEngine.lifecycleChannel.appIsResumed()
    }

    override fun dismiss() {
        try {
            flutterView.detachFromFlutterEngine()
            flutterEngine.lifecycleChannel.appIsDetached()
            flutterEngine.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "Clear flutter resource error when remove sub screen", e)
        }
        super.dismiss()
    }

    protected open fun getTransparencyMode(): TransparencyMode {
        return TransparencyMode.opaque
    }

    protected open fun getRenderMode(): RenderMode {
        return RenderMode.surface
    }
}