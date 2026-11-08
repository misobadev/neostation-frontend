import 'dart:io';

import 'package:flutter/services.dart';

/// Provides global keyboard navigation support for desktop platforms.
///
/// Implements a pattern similar to [GamepadNavigation], allowing for consistent
/// input handling across different input devices.
class KeyboardNavigation {
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;
  final VoidCallback? onPreviousTab;
  final VoidCallback? onNextTab;
  final VoidCallback? onSelectItem;
  final VoidCallback? onBack;
  final VoidCallback? onFavorite;
  final VoidCallback? onSettings;

  bool _isActive = false;
  bool _isInitialized = false;
  DateTime? _lastEventTime;

  /// Throttle duration to prevent input spamming.
  static const int _throttleDelayMs = 100;

  /// Indicates if the current platform supports desktop keyboard navigation.
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  KeyboardNavigation({
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onPreviousTab,
    this.onNextTab,
    this.onSelectItem,
    this.onBack,
    this.onFavorite,
    this.onSettings,
  });

  /// Initializes keyboard navigation by registering a global listener.
  ///
  /// Only executes on desktop platforms.
  void initialize() {
    if (!isDesktop || _isInitialized) return;

    ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
    _isInitialized = true;
  }

  /// Enables input processing for this instance.
  void activate() {
    if (!isDesktop) return;
    _isActive = true;
  }

  /// Disables input processing for this instance.
  void deactivate() {
    _isActive = false;
  }

  /// Indicates if this instance is currently active.
  bool get isActive => _isActive;

  /// Global handler for raw keyboard events.
  bool _handleKeyEvent(KeyEvent event) {
    if (!_isActive || !isDesktop || event is! KeyDownEvent) {
      return false;
    }

    final now = DateTime.now();

    // Prevent excessive event processing via throttling.
    if (_lastEventTime != null &&
        now.difference(_lastEventTime!).inMilliseconds < _throttleDelayMs) {
      // Consume directional keys even during throttle to prevent Flutter's
      // native focus system from moving independently.
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return true;
      }
      return true;
    }

    final key = event.logicalKey;
    bool handled = false;

    // === DIRECTIONAL NAVIGATION ===
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      onNavigateUp?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.keyS ||
        key == LogicalKeyboardKey.arrowDown) {
      onNavigateDown?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.keyA ||
        key == LogicalKeyboardKey.arrowLeft) {
      onNavigateLeft?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.arrowRight) {
      onNavigateRight?.call();
      handled = true;
    }
    // === TAB NAVIGATION ===
    else if (key == LogicalKeyboardKey.keyQ) {
      onPreviousTab?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.keyE) {
      onNextTab?.call();
      handled = true;
    }
    // === ACTION BUTTONS ===
    else if (key == LogicalKeyboardKey.enter) {
      onSelectItem?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.delete) {
      onBack?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.keyY) {
      onFavorite?.call();
      handled = true;
    } else if (key == LogicalKeyboardKey.escape) {
      onSettings?.call();
      handled = true;
    }

    if (handled) {
      _lastEventTime = now;
      return true; // Consume the event.
    }

    return false; // Propagate the event if not handled.
  }

  /// Releases the keyboard listener.
  void dispose() {
    if (_isInitialized && isDesktop) {
      ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
      _isInitialized = false;
    }
  }
}

/// Orchestrates the activation state of multiple [KeyboardNavigation] instances.
class KeyboardNavigationManager {
  static final List<VoidCallback> _onDeactivateCallbacks = [];
  static final List<VoidCallback> _onReactivateCallbacks = [];

  /// Registers lifecycle callbacks for bulk navigation management.
  static void registerCallbacks({
    required VoidCallback onDeactivate,
    required VoidCallback onReactivate,
  }) {
    _onDeactivateCallbacks.add(onDeactivate);
    _onReactivateCallbacks.add(onReactivate);
  }

  /// Removes registered lifecycle callbacks.
  static void unregisterCallbacks({
    required VoidCallback onDeactivate,
    required VoidCallback onReactivate,
  }) {
    _onDeactivateCallbacks.remove(onDeactivate);
    _onReactivateCallbacks.remove(onReactivate);
  }

  /// Disables all registered keyboard navigation instances.
  static void deactivateAll() {
    for (final callback in _onDeactivateCallbacks) {
      callback();
    }
  }

  /// Enables all registered keyboard navigation instances.
  static void reactivateAll() {
    for (final callback in _onReactivateCallbacks) {
      callback();
    }
  }

  /// Clears all registered callbacks from the manager.
  static void clearAll() {
    _onDeactivateCallbacks.clear();
    _onReactivateCallbacks.clear();
  }
}
