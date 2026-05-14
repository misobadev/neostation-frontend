import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Farewell modal displayed after a plan downgrade
class PlanFarewellModal extends StatefulWidget {
  final String oldPlanName;
  final String newPlanName;
  final VoidCallback? onClose;

  const PlanFarewellModal({
    super.key,
    required this.oldPlanName,
    required this.newPlanName,
    this.onClose,
  });

  /// Shows the plan farewell modal
  static void show(
    BuildContext context,
    String oldPlanName,
    String newPlanName,
  ) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => PlanFarewellModal(
        oldPlanName: oldPlanName,
        newPlanName: newPlanName,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  @override
  PlanFarewellModalState createState() => PlanFarewellModalState();
}

class PlanFarewellModalState extends State<PlanFarewellModal> {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();

    // Auto-focus to capture gamepad key events
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
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final oldPlanDisplay = _getPlanDisplayName(widget.oldPlanName);
    final newPlanDisplay = _getPlanDisplayName(widget.newPlanName);
    final oldPlanColor = _getPlanColor(widget.oldPlanName);

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
              // Farewell icon
              Container(
                width: 40.w,
                height: 40.h,
                decoration: BoxDecoration(
                  color: oldPlanColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20.w),
                ),
                child: Icon(
                  Symbols.sentiment_dissatisfied_rounded,
                  size: 20.sp,
                  color: oldPlanColor,
                ),
              ),

              SizedBox(height: 12.h),

              // Title
              Text(
                AppLocale.planFarewellTitle.getString(context),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: oldPlanColor,
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
                      text: AppLocale.planFarewellMessagePre.getString(context),
                    ),
                    TextSpan(
                      text: oldPlanDisplay,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: oldPlanColor,
                      ),
                    ),
                    TextSpan(
                      text: AppLocale.planFarewellMessageMid.getString(context),
                    ),
                    TextSpan(
                      text: newPlanDisplay,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _getPlanColor(widget.newPlanName),
                      ),
                    ),
                    TextSpan(
                      text: AppLocale.planFarewellMessagePost.getString(
                        context,
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: 12.h),

              // Additional message
              Container(
                padding: EdgeInsets.all(10.w),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(6.w),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  AppLocale.planUpgradeAnytime.getString(context),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    fontSize: 10.sp,
                  ),
                  textAlign: TextAlign.center,
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
                      backgroundColor: oldPlanColor,
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
