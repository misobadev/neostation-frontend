import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/widgets/neo_glass.dart';

/// Actionable settings tile: a bordered card with a leading icon, a
/// title/subtitle block and a trailing control (toggle or action button).
///
/// This is the shared extraction of the Directories card chrome, reused by the
/// Tools and Systems panels so every actionable settings list renders with the
/// same background, corner radius, focus border and spacing. Richer one-off
/// rows (destructive/monospace paths in Directories) keep their bespoke layout.
class SettingsCardRow extends StatelessWidget {
  /// Leading glyph.
  final IconData icon;

  /// Primary label.
  final String title;

  /// Secondary description; pass an empty string to omit it.
  final String subtitle;

  /// Maximum lines the subtitle may wrap to before it ellipsizes.
  final int subtitleMaxLines;

  /// Trailing control (e.g. [CustomToggleSwitch] or a SettingsActionButton).
  final Widget? trailing;

  /// Whether this row currently holds gamepad focus (drives the border and
  /// title/icon accent colour).
  final bool selected;

  /// Dims the icon/title/subtitle for unavailable rows. Does not itself block
  /// taps — pass `onTap: null` (and a disabled trailing control) to do that.
  final bool disabled;

  /// Optional extra content rendered beneath the title/subtitle row (e.g. a
  /// current-path chip).
  final Widget? belowContent;

  /// Touch handler. Gamepad selection is driven separately by the panel.
  final VoidCallback? onTap;

  const SettingsCardRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.subtitleMaxLines = 1,
    this.trailing,
    required this.selected,
    this.disabled = false,
    this.belowContent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final borderColor = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.outline.withValues(alpha: 0);
    final foreground = selected
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface.withValues(alpha: disabled ? 0.4 : 1.0);
    final subtitleForeground = selected
        ? theme.colorScheme.surface.withValues(alpha: disabled ? 0.25 : 0.6)
        : theme.colorScheme.onSurface.withValues(alpha: disabled ? 0.25 : 0.6);

    final row = Container(
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.onSurface
            : theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: borderColor, width: selected ? 2.r : 1.r),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12.r),
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: foreground, size: 20.r),
                  SizedBox(width: 12.r),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 12.r,
                            color: foreground,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty) ...[
                          SizedBox(height: 2.r),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 9.r,
                              color: subtitleForeground,
                            ),
                            maxLines: subtitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) SizedBox(width: 12.r),
                  ?trailing,
                ],
              ),
              ?belowContent,
            ],
          ),
        ),
      ),
    );

    final rimWidth = NeoGlass.borderWidthOf(context);
    final inset = rimWidth > 0 ? (rimWidth / 2 + 0.5).r : 0.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 12.r),
      child: rimWidth > 0
          ? NeoGlassRim(cornerRadius: 12.r, borderWidth: rimWidth, child: row)
          : row,
    );
  }
}
