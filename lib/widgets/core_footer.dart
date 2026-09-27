import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/utils/color.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:neostation/l10n/app_locale.dart';

import '../themes/corner_radii.dart';

/// Height of every [CoreFooter] strip, in logical (pre-`.r`) units.
///
/// Exposed so screens that float the footer over their content can pad the
/// scrollable by exactly the strip it sits on.
const double kCoreFooterHeight = 42;

/// Base footer class that eliminates duplicated code between games_footer and systems_footer.
abstract class CoreFooter extends StatefulWidget {
  const CoreFooter({super.key});

  /// Subclasses must implement this to define their controls (buttons).
  List<Widget> buildControls(BuildContext context);

  /// Optional left-side content (e.g. app name, system name).
  Widget? buildLeftContent(BuildContext context) => null;

  /// Whether controls should be centered (true) or right-aligned (false).
  bool get centerControls => true;

  /// Whether to show the app version (useful for hiding it in dense footers).
  bool get showVersion => centerControls;

  @override
  State<CoreFooter> createState() => _CoreFooterState();
}

class _CoreFooterState extends State<CoreFooter> {
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        _appVersion = 'v${packageInfo.version}';
      });
    } catch (e) {
      setState(() {
        _appVersion = 'v1.0.0'; // Fallback
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kCoreFooterHeight.r,
      decoration: BoxDecoration(
        color: widget.centerControls
            ? Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.5)
            : Colors.transparent,
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: widget.centerControls
          ? _buildCenteredLayout()
          : _buildSplitLayout(),
    );
  }

  Widget _buildCenteredLayout() {
    return Stack(
      children: [
        // Centered controls
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: widget.buildControls(context),
          ),
        ),
        // Version label on the right
        if (widget.showVersion && _appVersion.isNotEmpty)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Text(
                '${AppLocale.beta.getString(context)} $_appVersion',
                style: TextStyle(
                  fontSize: 12.r,
                  color: Theme.of(context).colorScheme.onSurface,
                  letterSpacing: 0.3.r,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplitLayout() {
    return Row(
      children: [
        // Left content
        Expanded(child: widget.buildLeftContent(context) ?? const SizedBox()),
        // Controls on the right
        Row(
          mainAxisSize: MainAxisSize.min,
          children: widget.buildControls(context),
        ),
      ],
    );
  }
}

/// Shared gamepad controls widget used by both footers.
class GamepadControl extends StatelessWidget {
  final dynamic iconPath; // Can be a String (asset path) or IconData
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final Color? textColor;
  final Gradient? gradient;

  /// Shows a spinner in place of the glyph and disables the tap while work is
  /// in flight (e.g. a download or a folder picker).
  final bool busy;

  const GamepadControl({
    super.key,
    this.iconPath,
    required this.label,
    this.icon,
    this.onTap,
    this.backgroundColor,
    this.textColor,
    this.gradient,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Default to a subtle semi-transparent style when no background color is provided.
    final Color buttonBg =
        backgroundColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.1);
    final Color contentColor = textColor ?? theme.colorScheme.onPrimary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        canRequestFocus: false,
        splashColor: contentColor.withValues(alpha: 0.2),
        highlightColor: Colors.transparent,
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(6.r),

        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: gradient == null ? buttonBg : null,
            gradient: gradient,
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                BorderRadius.circular(6.r),
            border: Border.all(color: lightenColor(buttonBg, 0.05), width: 1.r),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14.r,
                  height: 14.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.r,
                    valueColor: AlwaysStoppedAnimation<Color>(contentColor),
                  ),
                )
              // Material Design icon
              else if (icon != null)
                Icon(icon, size: 12.r, color: contentColor)
              // Asset image
              else if (iconPath is String)
                SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: Image.asset(
                    iconPath,
                    color: contentColor,
                    colorBlendMode: BlendMode.srcIn,
                  ),
                ),
              SizedBox(width: 4.r),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.r, // Slightly reduced so buttons fit comfortably
                  color: contentColor,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2.r,
                ),
              ),
              SizedBox(width: 4.r),
            ],
          ),
        ),
      ),
    );
  }
}
