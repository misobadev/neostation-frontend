import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/sqlite_config_provider.dart';

/// Shared policy for `user_config.performance_mode`.
///
/// Performance mode is a render-time override: it does not rewrite the user's
/// saved theme, glass or image-quality preferences. These helpers keep the
/// decisions in one place so every view trades the same effects for speed.
extension PerformanceModeContext on BuildContext {
  /// Whether performance mode is currently enabled.
  ///
  /// Uses `select` so a caller subscribes to just this flag and does not
  /// rebuild when unrelated config changes.
  bool get performanceMode {
    try {
      return select<SqliteConfigProvider, bool>(
        (provider) => provider.config.performanceMode,
      );
    } catch (_) {
      // Preview subtrees and small widget tests may not mount the provider.
      return false;
    }
  }
}

/// A moderately smaller decode width for performance mode.
///
/// The cap is deliberately not aggressive: 70% keeps cards and fanart legible
/// while cutting decode, texture memory and GPU bandwidth. A floor keeps tiny
/// icons from becoming mush.
int performanceCacheWidth(int desired, {required bool performanceMode}) {
  if (!performanceMode) return desired;
  return (desired * 0.7).round().clamp(64, 4096);
}
