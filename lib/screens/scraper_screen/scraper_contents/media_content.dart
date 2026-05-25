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
  final List<String> enabledTypes;
  final ValueChanged<List<String>> onEnabledTypesChanged;

  const MediaContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.enabledTypes,
    required this.onEnabledTypesChanged,
  });

  @override
  State<MediaContent> createState() => MediaContentState();
}

class MediaContentState extends State<MediaContent> {
  static const _orderedKeys = ['fanart', 'ss', 'wheel', 'box2D', 'video'];

  void selectItem(int index) {
    if (index >= 0 && index < _orderedKeys.length) {
      final key = _orderedKeys[index];
      final types = List<String>.from(widget.enabledTypes);
      if (types.contains(key)) {
        types.remove(key);
      } else {
        types.add(key);
      }
      widget.onEnabledTypesChanged(types);
    }
  }

  String _title(String key, BuildContext context) {
    switch (key) {
      case 'fanart':
        return AppLocale.scrapeFanart.getString(context);
      case 'ss':
        return AppLocale.scrapeScreenshot.getString(context);
      case 'wheel':
        return AppLocale.scrapeWheel.getString(context);
      case 'box2D':
        return AppLocale.scrapeBox2D.getString(context);
      case 'video':
        return AppLocale.scrapeVideo.getString(context);
      default:
        return key;
    }
  }

  String _description(String key, BuildContext context) {
    switch (key) {
      case 'fanart':
        return AppLocale.scrapeFanartDesc.getString(context);
      case 'ss':
        return AppLocale.scrapeScreenshotDesc.getString(context);
      case 'wheel':
        return AppLocale.scrapeWheelDesc.getString(context);
      case 'box2D':
        return AppLocale.scrapeBox2DDesc.getString(context);
      case 'video':
        return AppLocale.scrapeVideoDesc.getString(context);
      default:
        return '';
    }
  }

  IconData _icon(String key) {
    switch (key) {
      case 'fanart':
        return Symbols.wallpaper_rounded;
      case 'ss':
        return Symbols.screenshot_rounded;
      case 'wheel':
        return Symbols.title_rounded;
      case 'box2D':
        return Symbols.inventory_2_rounded;
      case 'video':
        return Symbols.videocam_rounded;
      default:
        return Symbols.image_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.media.getString(context),
            subtitle: AppLocale.mediaSub.getString(context),
          ),
          SizedBox(height: 12.h),
          ..._orderedKeys.asMap().entries.map((entry) {
            final index = entry.key;
            final key = entry.value;
            final isChecked = widget.enabledTypes.contains(key);
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
                          _title(key, context),
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
                          _description(key, context),
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
                      final types = List<String>.from(widget.enabledTypes);
                      if (value) {
                        types.add(key);
                      } else {
                        types.remove(key);
                      }
                      widget.onEnabledTypesChanged(types);
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
