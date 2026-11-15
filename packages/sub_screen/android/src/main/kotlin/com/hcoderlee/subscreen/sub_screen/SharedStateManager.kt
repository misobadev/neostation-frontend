package com.hcoderlee.subscreen.sub_screen

typealias SharedState = Map<String, Any>?
typealias OnSharedStateChange = (type: String, state: SharedState) -> Unit

object SharedStateManager {
    private val sharedStats = mutableMapOf<String, SharedState>()
    private val listeners = mutableSetOf<OnSharedStateChange>()

    fun getState(type: String): SharedState {
        return sharedStats[type]
    }

    fun getAllState(): Map<String, SharedState> {
        return sharedStats
    }

    fun removeState(type: String) {
        if (!sharedStats.contains(type)) {
            return
        }
        sharedStats.remove(type)
        notifyListener(type, null)
    }

    fun updateState(type: String, state: SharedState) {
        sharedStats[type] = state
        notifyListener(type, state)
    }

    fun addOnStateChangeListener(listener: OnSharedStateChange) {
        listeners.add(listener)
    }

    fun removeOnStateChangeListener(listener: OnSharedStateChange) {
        listeners.remove(listener)
    }

    private fun notifyListener(type: String, state: SharedState) {
        listeners.forEach { it(type, state) }
    }
}