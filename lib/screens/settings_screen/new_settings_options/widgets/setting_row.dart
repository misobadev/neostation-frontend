import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/widgets/neo_glass.dart';

/// A single focus-bordered settings row: a title/subtitle block paired with a
/// trailing control (toggle, dropdown, etc.).
///
/// Encapsulates the shared chrome — surface background, rounded border that
/// highlights in the theme's primary colour while focused, and the standard
/// title/subtitle typography — so individual settings only declare their
/// label, description, and trailing widget.
class SettingRow extends StatelessWidget {
  /// Primary label text.
  final String title;

  /// Secondary description text shown beneath the title. Ignored when
  /// [subtitleWidget] is provided.
  final String subtitle;

  /// Optional custom widget rendered beneath the title in place of the plain
  /// [subtitle] text — for rows needing richer secondary content (e.g. a
  /// coloured permission-status line).
  final Widget? subtitleWidget;

  /// The control rendered at the trailing edge of the row.
  final Widget trailing;

  /// Whether this row currently owns gamepad focus (drives the border and
  /// title colour).
  final bool focused;

  /// Whether the title/subtitle block is wrapped in an [Expanded]. Defaults to
  /// `true`; a small number of legacy rows lay out without it.
  final bool expandTitle;

  /// Touch handler for the entire row.
  final VoidCallback? onTap;

  const SettingRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.subtitleWidget,
    required this.trailing,
    required this.focused,
    this.expandTitle = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = focused
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface;
    final subtitleForeground = focused
        ? theme.colorScheme.surface.withValues(alpha: 0.6)
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: 12.r,
            fontWeight: FontWeight.w500,
            color: foreground,
          ),
        ),
        SizedBox(height: 4.r),
        if (subtitleWidget != null)
          subtitleWidget!
        else
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 9.r,
              color: subtitleForeground,
            ),
          ),
      ],
    );

    final row = Container(
      decoration: BoxDecoration(
        color: focused
            ? theme.colorScheme.onSurface
            : theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: focused ? theme.colorScheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8.r),
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12.r,
              right: 12.r,
              top: 6.r,
              bottom: 6.r,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                expandTitle ? Expanded(child: titleColumn) : titleColumn,
                SizedBox(width: 12.r),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );

    final rimWidth = NeoGlass.borderWidthOf(context);
    if (rimWidth <= 0) return row;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: (rimWidth / 2 + 0.5).r),
      child: NeoGlassRim(cornerRadius: 8.r, borderWidth: rimWidth, child: row),
    );
  }
}
