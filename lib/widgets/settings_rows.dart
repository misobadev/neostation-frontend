import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/models/core_emulator_model.dart';

/// Generic settings row with icon, label, and custom trailing widget.
///
/// Shared by the game details settings tab and the game settings dialog so
/// both render identical, gamepad-highlightable rows.
class SettingsRow extends StatelessWidget {
  final bool isSelected;
  final IconData icon;
  final String label;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsRow({
    super.key,
    required this.isSelected,
    required this.icon,
    required this.label,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 4.r),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
          child: Row(
            children: [
              Container(
                width: 18.r,
                height: 18.r,
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.secondary.withValues(alpha: 0.2)
                      : theme.colorScheme.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4.r),
                ),
                child: Icon(
                  icon,
                  color: isSelected
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.onSurface,
                  size: 11.r,
                ),
              ),
              SizedBox(width: 8.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: isSelected
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.onSurface,
                        fontSize: 12.r,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 1.r),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                        fontSize: 10.r,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Specialized row for emulator selection, including installation and
/// compatibility status. Shared by the game details settings tab and the
/// game settings dialog.
class EmulatorRow extends StatelessWidget {
  final bool isSelected;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final CoreEmulatorModel? emulator;

  const EmulatorRow({
    super.key,
    required this.isSelected,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.emulator,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = isSelected ? scheme.surface : scheme.onSurface;
    final raCompatible = emulator?.isretroAchievementsCompatible ?? false;
    final installed = emulator?.isInstalled ?? true;
    final disabled = emulator != null && !installed;

    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Container(
          margin: EdgeInsets.only(bottom: 4.r),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.onSurface
                : scheme.surfaceContainerHighest.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6.r),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Branding Icon: Defaults to RetroArch but supports extensibility.
                Container(
                  width: 22.r,
                  height: 22.r,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? scheme.surface.withValues(alpha: 0.12)
                        : scheme.secondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4.r),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(3.r),
                    child: Image.asset(
                      'assets/images/emulators/retroarch.webp',
                      color: foreground,
                      colorBlendMode: BlendMode.srcIn,
                      errorBuilder: (_, _, _) => Icon(
                        Symbols.gamepad_rounded,
                        size: 12.r,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 8.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                      SizedBox(height: 1.r),
                      Row(
                        children: [
                          // Compatibility Indicator: RetroAchievements support.
                          if (raCompatible)
                            Container(
                              margin: EdgeInsets.only(right: 5.r),
                              padding: EdgeInsets.symmetric(
                                horizontal: 4.r,
                                vertical: 1.r,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFD700),
                                borderRadius: BorderRadius.circular(3.r),
                                border: Border.all(
                                  color: const Color(
                                    0xFF00387D,
                                  ).withValues(alpha: 0.2),
                                  width: 0.5.r,
                                ),
                              ),
                              child: Icon(
                                Symbols.emoji_events_rounded,
                                size: 9.r,
                                color: const Color(0xFF00387D),
                              ),
                            ),
                          // Installation Status Indicator.
                          if (emulator != null)
                            Row(
                              children: [
                                Icon(
                                  installed
                                      ? Symbols.check_circle_rounded
                                      : Symbols.error_outline_rounded,
                                  size: 10.r,
                                  color: installed
                                      ? const Color(0xFF56C288)
                                      : const Color(0xFFFDAF1E),
                                ),
                                SizedBox(width: 3.r),
                                Text(
                                  installed ? 'Ready' : 'Not configured',
                                  style: TextStyle(
                                    fontSize: 10.r,
                                    color: foreground,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Active Override Indicator.
                if (isActive)
                  Icon(
                    Symbols.check_circle_rounded,
                    size: 14.r,
                    color: foreground,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
