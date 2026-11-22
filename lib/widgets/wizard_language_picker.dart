import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../themes/corner_radii.dart';

/// The first step of the app's wizards: every language NeoStation speaks,
/// each in its own name, as a grid of tiles. The selected one takes the main
/// button's colours (tertiary), the rest the other buttons' (tertiaryFixed).
///
/// [unit] scales every size, as for [WizardStepDots].
class WizardLanguagePicker extends StatelessWidget {
  const WizardLanguagePicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.unit = 1,
    this.dense = false,
    this.fontSize = 14,
  });

  /// Tiles per row; the D-pad moves a row up or down by this many.
  static const int columns = 4;

  static List<String> get codes => AppLocale.supportedLanguages.keys.toList();

  /// The language [delta] tiles away from [current] (±1 across a row,
  /// ±[columns] up and down), staying on the grid.
  static String move(String current, int delta) {
    final all = codes;
    final index = all.indexOf(current);
    if (index < 0) return all.first;
    final next = index + delta;
    if (next < 0 || next >= all.length) return current;
    return all[next];
  }

  final String selected;
  final ValueChanged<String> onSelected;
  final double unit;

  /// Tighter tiles and gaps, so the three rows fit on a short screen.
  final bool dense;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(
      (theme.extension<CornerRadii>()?.radiusInternalRaw ?? 10) * unit,
    );
    final spacing = (dense ? 6 : 8) * unit;
    // Always [columns] tiles a row, sized to the space there is: the D-pad
    // moves by [columns] up and down, so the grid must not reflow.
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            ((constraints.maxWidth - spacing * (columns - 1)) / columns).clamp(
              0.0,
              150 * unit,
            );
        return _grid(context, tileWidth, spacing, radius, scheme);
      },
    );
  }

  Widget _grid(
    BuildContext context,
    double tileWidth,
    double spacing,
    BorderRadius radius,
    ColorScheme scheme,
  ) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final entry in AppLocale.supportedLanguages.entries)
          Builder(
            builder: (context) {
              final isSelected = entry.key == selected;
              return Semantics(
                selected: isSelected,
                button: true,
                child: Material(
                  color: isSelected ? scheme.tertiary : scheme.tertiaryFixed,
                  borderRadius: radius,
                  child: InkWell(
                    borderRadius: radius,
                    canRequestFocus: false,
                    onTap: () => onSelected(entry.key),
                    child: Container(
                      width: tileWidth,
                      padding: EdgeInsets.symmetric(
                        horizontal: 6 * unit,
                        vertical: (dense ? 5 : 8) * unit,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: isSelected
                              ? scheme.tertiary
                              : scheme.onTertiaryFixed.withValues(alpha: 0.12),
                          width: unit,
                        ),
                      ),
                      // A long name shrinks to fit rather than being cut.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          entry.value,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: fontSize * unit,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isSelected
                                ? scheme.onTertiary
                                : scheme.onTertiaryFixed,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
