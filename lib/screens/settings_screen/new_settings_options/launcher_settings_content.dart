import 'package:flutter/material.dart';

import 'settings_title.dart';

/// Launcher settings content widget (Android only)
class LauncherSettingsContent extends StatelessWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const LauncherSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  int getItemCount() {
    return 0; // No focusable items yet
  }

  void selectItem(int index) {
    // No items to select yet
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsTitle(
          title: 'Launcher',
          subtitle: 'Configure launcher settings (Android only)',
        ),
      ],
    );
  }
}
