import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'settings_title.dart';

class AboutSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const AboutSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<AboutSettingsContent> createState() => AboutSettingsContentState();
}

class AboutSettingsContentState extends State<AboutSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  String _appVersion = '';
  String _systemsVersion = '';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _loadSystemsVersion();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      (index * 110.h).clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _loadSystemsVersion() async {
    try {
      final version = await SqliteService.getSystemsVersion();
      if (mounted) {
        setState(() {
          _systemsVersion = version.isNotEmpty ? version : 'bundled';
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = 'v${packageInfo.version}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _appVersion = 'v1.0.0';
        });
      }
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  int getItemCount() {
    return 5;
  }

  void selectItem(int index) {
    switch (index) {
      case 0:
        _launchUrl('https://github.com/misobadev/neostation-frontend');
        break;
      case 1:
        _launchUrl('https://ko-fi.com/neostation');
        break;
      case 2:
        _launchUrl('https://www.patreon.com/cw/NeoStation');
        break;
      case 3:
        _launchUrl('https://discord.gg/xE2kgKsRVq');
        break;
      case 4:
        _launchUrl('https://neostation.dev/');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(title: AppLocale.thankYou.getString(context)),
          SizedBox(height: 12.r),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.r),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    SizedBox(
                      width: 64.r,
                      height: 64.r,
                      child: Image.asset(
                        'assets/images/logo_transparent.png',
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => Icon(
                          Symbols.games_rounded,
                          size: 64.r,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    SizedBox(height: 6.r),
                    Text(
                      'NeoStation',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.r,
                      ),
                    ),
                    SizedBox(height: 1.h),
                    Text(
                      "Beta $_appVersion",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 9.r,
                      ),
                    ),
                    SizedBox(height: 1.h),
                    Text(
                      'Systems v$_systemsVersion',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.4,
                        ),
                        fontSize: 8.r,
                      ),
                    ),
                  ],
                ),
                SizedBox(width: 16.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildInfoCard(
                        icon: Symbols.code_rounded,
                        title: AppLocale.openSourceLicense.getString(context),
                        value: AppLocale.openSourceLicenseDesc.getString(
                          context,
                        ),
                        url: 'https://github.com/misobadev/neostation-frontend',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 0,
                      ),
                      SizedBox(height: 8.h),
                      _buildInfoCard(
                        icon: Symbols.coffee_rounded,
                        title: AppLocale.supportOnKofi.getString(context),
                        value: 'ko-fi.com/neostation',
                        url: 'https://ko-fi.com/neostation',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 1,
                      ),
                      SizedBox(height: 8.h),
                      _buildInfoCard(
                        icon: Symbols.favorite_rounded,
                        title: AppLocale.supportOnPatreon.getString(context),
                        value: 'patreon.com/NeoStation',
                        url: 'https://www.patreon.com/cw/NeoStation',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 2,
                      ),
                      SizedBox(height: 8.h),
                      _buildInfoCard(
                        icon: Symbols.chat_bubble_outline_rounded,
                        title: AppLocale.joinCommunity.getString(context),
                        value: 'discord.gg/xE2kgKsRVq',
                        url: 'https://discord.gg/xE2kgKsRVq',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 3,
                      ),
                      SizedBox(height: 8.h),
                      _buildInfoCard(
                        icon: Symbols.language_rounded,
                        title: AppLocale.visitWebsite.getString(context),
                        value: 'neostation.dev',
                        url: 'https://neostation.dev/',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 4,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required String url,
    required ThemeData theme,
    bool isFocused = false,
  }) {
    return InkWell(
      onTap: () {
        SfxService().playNavSound();
        _launchUrl(url);
      },
      borderRadius: BorderRadius.circular(12.r),
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      child: Container(
        padding: EdgeInsets.all(6.r),
        decoration: BoxDecoration(
          color: theme.cardColor.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            SizedBox(width: 8.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.r,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    value,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                      fontSize: 9.r,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Symbols.open_in_new_rounded,
              size: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
