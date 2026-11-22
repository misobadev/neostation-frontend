import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Scrolls a [ScrollController] to a target on a critically damped spring
/// that keeps its speed when the target changes.
///
/// `animateTo` starts every call from rest on a fresh curve, so a run of
/// D-pad presses scrolled in a series of starts and stops. Here a new target
/// only moves where the spring pulls: the scroll carries on at the speed it
/// had, eases into the new target and stops without overshooting.
///
/// A drag or fling by the user takes over at once: the spring notices the
/// position moved under it and lets go.
class SpringScroller {
  SpringScroller(this.controller, TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  final ScrollController controller;
  late final Ticker _ticker;

  // About a quarter of a second to cover most of the way, half a second to
  // settle, never past the target.
  static const double _stiffness = 170;
  static final double _damping = 2 * math.sqrt(_stiffness);
  static const double _step = 1 / 240;

  double _target = 0;
  double _velocity = 0;
  double? _last;
  Duration _lastTick = Duration.zero;

  bool get isAnimating => _ticker.isActive;

  /// Where the scroll is heading while it animates.
  double get target => _target;

  /// Starts (or redirects) the scroll towards [offset].
  void animateTo(double offset) {
    if (!controller.hasClients) return;
    _target = offset;
    if (!_ticker.isActive) {
      _velocity = 0;
      _last = controller.position.pixels;
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  /// Lets go of the scroll where it is.
  void stop() {
    if (_ticker.isActive) _ticker.stop();
    _velocity = 0;
    _last = null;
  }

  void _tick(Duration elapsed) {
    if (!controller.hasClients) {
      stop();
      return;
    }
    final position = controller.position;
    var pixels = position.pixels;
    // Someone else moved it (a drag, a fling): theirs now.
    final last = _last;
    if (last != null && (pixels - last).abs() > 0.5) {
      stop();
      return;
    }
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    var left = math.min(dt, 0.1);
    while (left > 0) {
      final h = math.min(_step, left);
      left -= h;
      final pull = (_target - pixels) * _stiffness - _velocity * _damping;
      _velocity += pull * h;
      pixels += _velocity * h;
    }
    pixels = pixels.clamp(position.minScrollExtent, position.maxScrollExtent);
    final done = (_target - pixels).abs() < 0.5 && _velocity.abs() < 5;
    if (done) {
      pixels = _target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    }
    position.jumpTo(pixels);
    _last = position.pixels;
    if (done) stop();
  }

  void dispose() {
    _ticker.dispose();
  }
}
