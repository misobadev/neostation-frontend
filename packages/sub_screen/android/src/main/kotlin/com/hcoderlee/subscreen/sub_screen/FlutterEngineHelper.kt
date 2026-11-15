package com.hcoderlee.subscreen.sub_screen

import android.content.Context
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.FlutterEngineGroupCache

object FlutterEngineHelper {
    private var hasInit = false

    const val ENGINE_GROUP_ID = "sub_screen_engine_group"

    fun init(context: Context) {
        if (hasInit) {
            return
        }
        hasInit = true

        // The flutter engine group to spawn all of the flutter engine of the app
        val engineGroup = FlutterEngineGroup(context)
        FlutterEngineGroupCache.getInstance().put(ENGINE_GROUP_ID, engineGroup)
    }
}