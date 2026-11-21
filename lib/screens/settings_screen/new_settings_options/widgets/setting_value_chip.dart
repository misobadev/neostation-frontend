import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/corner_radii.dart';

/// Compact pill showing the current value of a settings row (language, a
/// cyclable option, etc.). Pair it as the [SettingRow.trailing] control; wrap
/// the owning row in a tap handler to cycle or open a picker.
///
/// Optionally renders a trailing glyph (e.g. a dropdown caret) to signal that
/// tapping opens a picker.
class SettingValueChip extends StatelessWidget {
  /// Text of the current value.
  final String text;

  /// Optional trailing glyph, e.g. a dropdown caret for picker-backed rows.
  final IconData? trailingIcon;

  const SettingValueChip({super.key, required this.text, this.trailingIcon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(
          (Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m())
                  .radiusInternalRadius *
              0.6,
        ),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
          width: 0.5.r,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 9.r,
              fontWeight: FontWeight.w400,
              color: theme.colorScheme.primary,
            ),
          ),
          if (trailingIcon != null) ...[
            SizedBox(width: 2.r),
            Icon(trailingIcon, size: 14.r, color: theme.colorScheme.primary),
          ],
        ],
      ),
    );
  }
}
