import 'package:flutter/widgets.dart';

/// User-selected width and density for the games list view.
enum GameListLayout {
  standard('standard', 0.40, 1.0),
  wide('wide', 0.55, 1.25),
  extraWide('extra_wide', 0.60, 1.25);

  final String value;
  final double listFraction;
  final double contentScale;

  const GameListLayout(this.value, this.listFraction, this.contentScale);

  static GameListLayout fromValue(String? value) =>
      GameListLayout.values.firstWhere(
        (layout) => layout.value == value,
        orElse: () => GameListLayout.standard,
      );
}

/// Multiplies a platform text scaler while preserving its scaling curve.
class GameListTextScaler extends TextScaler {
  final TextScaler parent;
  final double multiplier;

  const GameListTextScaler(this.parent, this.multiplier);

  @override
  double scale(double fontSize) => parent.scale(fontSize) * multiplier;

  @override
  double get textScaleFactor => parent.scale(14) / 14 * multiplier;

  @override
  bool operator ==(Object other) =>
      other is GameListTextScaler &&
      other.parent == parent &&
      other.multiplier == multiplier;

  @override
  int get hashCode => Object.hash(parent, multiplier);
}
