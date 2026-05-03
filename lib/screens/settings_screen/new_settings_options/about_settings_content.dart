import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'settings_title.dart';

/// A specialized content panel for application metadata, community links, and contributor attribution.
///
/// Orchestrates dynamic version extraction from the build manifest, handles
/// external URL dispatching for social/web platforms, and displays project credits.
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

  /// Synchronizes the scroll viewport with the focused community link.
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

  /// Extracts the application version string from the platform package info.
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
          _appVersion = 'v1.0.0'; // Fallback version string.
        });
      }
    }
  }

  /// Dispatches a URL request to the platform's default external application.
  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Returns the count of navigable external links.
  int getItemCount() {
    return 2; // Primary Web and Community Discord links.
  }

  /// Executes the external link action for the specified index.
  void selectItem(int index) {
    if (index == 0) {
      _launchUrl('https://neostation.dev/');
    } else if (index == 1) {
      _launchUrl('https://discord.gg/xE2kgKsRVq');
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
                // Metadata Section: Identity, Branding, and Lifecycle Versioning.
                Column(
                  children: [
                    SizedBox(
                      width: 64.r,
                      height: 64.r,
                      child: Image.asset(
                        'assets/images/logo_transparent.png',
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => Icon(
                          Icons.games,
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

                // Interaction Section: Community Access and External Portals.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildInfoCard(
                        icon: Icons.language,
                        title: AppLocale.visitWebsite.getString(context),
                        value: 'neostation.dev',
                        url: 'https://neostation.dev/',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 0,
                      ),
                      SizedBox(height: 8.h),
                      _buildInfoCard(
                        icon: Icons.chat_bubble_outline,
                        title: AppLocale.joinCommunity.getString(context),
                        value: 'discord.gg/xE2kgKsRVq',
                        url: 'https://discord.gg/xE2kgKsRVq',
                        theme: theme,
                        isFocused:
                            widget.isContentFocused &&
                            widget.selectedContentIndex == 1,
                      ),
                      SizedBox(height: 8.h),
                      _buildCreditsCard(theme),
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

  /// Constructs the contributor attribution card.
  Widget _buildCreditsCard(ThemeData theme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28.r,
                height: 28.r,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Icon(
                  Icons.favorite,
                  size: 16.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.specialThanks.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 12.r,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          _buildCreditItem(
            'Reckkles, Sekyom, PaulStranger, Moderators & Supporters',
            AppLocale.forInvaluableContributions.getString(context),
            theme,
          ),
        ],
      ),
    );
  }

  /// Constructs an individual attribution entry with title and descriptive context.
  Widget _buildCreditItem(String name, String description, ThemeData theme) {
    return Padding(
      padding: EdgeInsets.only(left: 6.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 3.h),
            child: Icon(
              Icons.check_circle,
              size: 12.r,
              color: theme.colorScheme.primary.withValues(alpha: 0.7),
            ),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                    fontSize: 9.r,
                  ),
                ),
                SizedBox(height: 1.h),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 9.r,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Constructs a clickable information card for community portals.
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
            color: isFocused
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withValues(alpha: 0),
            width: isFocused ? 2.r : 1.r,
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
              Icons.open_in_new,
              size: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
