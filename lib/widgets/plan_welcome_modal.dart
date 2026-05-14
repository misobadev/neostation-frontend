import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Welcome modal shown after a successful plan upgrade
class PlanWelcomeModal extends StatefulWidget {
  final String planName;
  final VoidCallback? onClose;

  const PlanWelcomeModal({super.key, required this.planName, this.onClose});

  /// Shows the plan welcome modal
  static void show(BuildContext context, String planName) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => PlanWelcomeModal(
        planName: planName,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  @override
  PlanWelcomeModalState createState() => PlanWelcomeModalState();
}

class PlanWelcomeModalState extends State<PlanWelcomeModal> {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();

    // Auto-focus to capture gamepad keys
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _handleClose() {
    widget.onClose?.call();
  }

  void _handleKeyPress(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Escape, Enter, or Space to close
      if (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.space) {
        _handleClose();
      }
    }
  }

  String _getPlanDisplayName(String planName) {
    switch (planName.toLowerCase()) {
      case 'free':
        return 'FREE';
      case 'micro':
        return 'MICRO';
      case 'mini':
        return 'MINI';
      case 'mega':
        return 'MEGA';
      case 'ultra':
        return 'ULTRA';
      default:
        return planName.toUpperCase();
    }
  }

  Color _getPlanColor(String planName) {
    switch (planName.toLowerCase()) {
      case 'free':
        return Colors.grey;
      case 'micro':
        return Colors.blue;
      case 'mini':
        return Colors.green;
      case 'mega':
        return Colors.orange;
      case 'ultra':
        return Colors.purple;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final planDisplayName = _getPlanDisplayName(widget.planName);
    final planColor = _getPlanColor(widget.planName);

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyPress,
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.w),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.6,
          constraints: BoxConstraints(maxWidth: 350.w),
          padding: EdgeInsets.all(16.w),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Celebration icon
              Container(
                width: 40.w,
                height: 40.h,
                decoration: BoxDecoration(
                  color: planColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20.w),
                ),
                child: Icon(Symbols.celebration_rounded, size: 20.sp, color: planColor),
              ),

              SizedBox(height: 12.h),

              // Title
              Text(
                AppLocale.planWelcomeTitle.getString(context),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: planColor,
                  fontSize: 16.sp,
                ),
                textAlign: TextAlign.center,
              ),

              SizedBox(height: 8.h),

              // Main message
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontSize: 11.sp),
                  children: [
                    TextSpan(
                      text: AppLocale.planWelcomeMessagePre.getString(context),
                    ),
                    TextSpan(
                      text: planDisplayName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: planColor,
                      ),
                    ),
                    TextSpan(
                      text: AppLocale.planWelcomeMessagePost.getString(context),
                    ),
                  ],
                ),
              ),

              SizedBox(height: 16.h),

              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Close button
                  ElevatedButton.icon(
                    onPressed: _handleClose,
                    icon: Icon(Symbols.close_rounded, size: 14.sp),
                    label: Text(
                      AppLocale.close.getString(context),
                      style: TextStyle(fontSize: 11.sp),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: planColor,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: 16.w,
                        vertical: 8.h,
                      ),
                    ),
                  ),
                ],
              ),

              SizedBox(height: 8.h),

              // Gamepad instruction
              Text(
                AppLocale.pressToClose.getString(context),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 9.sp,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
