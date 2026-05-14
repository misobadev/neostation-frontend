import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';

class MediaContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final Map<String, bool> currentConfig;
  final ValueChanged<Map<String, bool>> onConfigChanged;

  const MediaContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.currentConfig,
    required this.onConfigChanged,
  });

  @override
  State<MediaContent> createState() => MediaContentState();
}

class MediaContentState extends State<MediaContent> {
  final List<String> _optionKeys = ['scrape_images', 'scrape_videos'];

  void selectItem(int index) {
    if (index >= 0 && index < _optionKeys.length) {
      final key = _optionKeys[index];
      final newValue = !(widget.currentConfig[key] ?? true);

      final newConfig = Map<String, bool>.from(widget.currentConfig);
      newConfig[key] = newValue;

      widget.onConfigChanged(newConfig);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final options = [
      {
        'key': 'scrape_images',
        'title': AppLocale.scrapeImages.getString(context),
        'description': AppLocale.scrapeImagesDesc.getString(context),
        'icon': Symbols.image_rounded,
      },
      {
        'key': 'scrape_videos',
        'title': AppLocale.scrapeVideos.getString(context),
        'description': AppLocale.scrapeVideosDesc.getString(context),
        'icon': Symbols.videocam_rounded,
      },
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.media.getString(context),
            subtitle: AppLocale.mediaSub.getString(context),
          ),
          SizedBox(height: 12.h),
          ...options.asMap().entries.map((entry) {
            final index = entry.key;
            final option = entry.value;
            final key = option['key'].toString();
            final isChecked = widget.currentConfig[key] ?? true;
            final isFocused =
                widget.isContentFocused && widget.selectedContentIndex == index;

            return Container(
              margin: EdgeInsets.only(bottom: 8.h),
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  width: 1.r,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          option['title'].toString(),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color: isFocused
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 2.r),
                        Text(
                          option['description'].toString(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 10.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: isChecked,
                    onChanged: (value) {
                      final newConfig = Map<String, bool>.from(
                        widget.currentConfig,
                      );
                      newConfig[key] = value;
                      widget.onConfigChanged(newConfig);
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
