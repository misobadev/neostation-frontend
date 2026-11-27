import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/metadata_provider_service.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';

import 'neoassets/neoassets_brand.dart';
import 'neoassets/neoassets_login_dialog.dart';
import 'neoassets/neoassets_settings_content.dart';
import 'screenscraper/screenscraper_login_dialog.dart';
import 'screenscraper/screenscraper_settings_content.dart';
import 'settings_title.dart';

/// Settings → Metadata: the user picks one metadata provider, NeoAssets or
/// ScreenScraper, and configures it here.
///
/// Only one provider holds a session at a time. Signed out of both, the page
/// is a chooser comparing the two; signed in, it hosts that provider's own
/// page (the ScreenScraper one unchanged) and hands it the gamepad.
class MetadataSettingsContent extends StatefulWidget {
  final bool isContentFocused;

  const MetadataSettingsContent({super.key, required this.isContentFocused});

  @override
  State<MetadataSettingsContent> createState() =>
      MetadataSettingsContentState();
}

enum _Mode { loading, chooser, neoAssets, screenScraper }

class MetadataSettingsContentState extends State<MetadataSettingsContent> {
  final GlobalKey<NeoAssetsSettingsContentState> _neoAssetsKey = GlobalKey();
  final GlobalKey<ScreenScraperSettingsContentState> _screenScraperKey =
      GlobalKey();

  _Mode _mode = _Mode.loading;

  /// Chooser cursor: 0 NeoAssets, 1 ScreenScraper.
  int _choice = 0;

  @override
  void initState() {
    super.initState();
    _resolveMode();
  }

  @override
  void didUpdateWidget(covariant MetadataSettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isContentFocused && !widget.isContentFocused) _choice = 0;
  }

  Future<void> _resolveMode() async {
    final active = await MetadataProviderService.active();
    if (!mounted) return;
    setState(() {
      _mode = switch (active) {
        MetadataProviderKind.neoAssets => _Mode.neoAssets,
        MetadataProviderKind.screenScraper => _Mode.screenScraper,
        null => _Mode.chooser,
      };
    });
  }

  // ==========================================
  // GAMEPAD NAVIGATION (driven by NewSettingsScreen)
  // ==========================================

  int getItemCount() => switch (_mode) {
    _Mode.loading => 0,
    _Mode.chooser => 2,
    _Mode.neoAssets => _neoAssetsKey.currentState?.getItemCount() ?? 0,
    _Mode.screenScraper => _screenScraperKey.currentState?.getItemCount() ?? 0,
  };

  bool navigateUp() => switch (_mode) {
    _Mode.chooser => _moveChoice(-1),
    _Mode.neoAssets => _neoAssetsKey.currentState?.navigateUp() ?? false,
    _Mode.screenScraper =>
      _screenScraperKey.currentState?.navigateUp() ?? false,
    _Mode.loading => false,
  };

  bool navigateDown() => switch (_mode) {
    _Mode.chooser => _moveChoice(1),
    _Mode.neoAssets => _neoAssetsKey.currentState?.navigateDown() ?? false,
    _Mode.screenScraper =>
      _screenScraperKey.currentState?.navigateDown() ?? false,
    _Mode.loading => false,
  };

  /// Returns true when focus should go back to the category menu.
  bool navigateLeft() => switch (_mode) {
    _Mode.chooser => _choice == 0 || !_moveChoice(-1),
    _Mode.neoAssets => _neoAssetsKey.currentState?.navigateLeft() ?? true,
    _Mode.screenScraper =>
      _screenScraperKey.currentState?.navigateLeft() ?? true,
    _Mode.loading => true,
  };

  void navigateRight() {
    switch (_mode) {
      case _Mode.chooser:
        if (_moveChoice(1)) SfxService().playNavSound();
      case _Mode.neoAssets:
        _neoAssetsKey.currentState?.navigateRight();
      case _Mode.screenScraper:
        _screenScraperKey.currentState?.navigateRight();
      case _Mode.loading:
        break;
    }
  }

  bool navigateBack() => switch (_mode) {
    _Mode.neoAssets => _neoAssetsKey.currentState?.navigateBack() ?? false,
    _Mode.screenScraper =>
      _screenScraperKey.currentState?.navigateBack() ?? false,
    _ => false,
  };

  void selectItem() {
    switch (_mode) {
      case _Mode.chooser:
        _choose(
          _choice == 0
              ? MetadataProviderKind.neoAssets
              : MetadataProviderKind.screenScraper,
        );
      case _Mode.neoAssets:
        _neoAssetsKey.currentState?.selectItem();
      case _Mode.screenScraper:
        _screenScraperKey.currentState?.selectItem();
      case _Mode.loading:
        break;
    }
  }

  bool _moveChoice(int delta) {
    final next = (_choice + delta).clamp(0, 1);
    if (next == _choice) return false;
    setState(() => _choice = next);
    return true;
  }

  // ==========================================
  // ACTIONS
  // ==========================================

  Future<void> _choose(MetadataProviderKind kind) async {
    setState(() => _choice = kind == MetadataProviderKind.neoAssets ? 0 : 1);
    if (kind == MetadataProviderKind.neoAssets &&
        !NeoAssetsScrapeService.isAvailable) {
      AppNotification.showNotification(
        context,
        AppLocale.neoAssetsNotConfigured.getString(context),
        type: NotificationType.error,
      );
      return;
    }
    final signedIn = kind == MetadataProviderKind.neoAssets
        ? await NeoAssetsLoginDialog.show(context)
        : await ScreenScraperLoginDialog.show(context);
    if (!signedIn || !mounted) return;

    // One session per user: the provider just chosen replaces the other.
    await MetadataProviderService.signOut(
      kind == MetadataProviderKind.neoAssets
          ? MetadataProviderKind.screenScraper
          : MetadataProviderKind.neoAssets,
    );
    if (!mounted) return;
    setState(
      () => _mode = kind == MetadataProviderKind.neoAssets
          ? _Mode.neoAssets
          : _Mode.screenScraper,
    );
  }

  /// Signs out of NeoAssets after confirming, back to the chooser.
  Future<void> _leaveNeoAssets() async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.switchProvider.getString(context),
      body: AppLocale.switchProviderDesc
          .getString(context)
          .replaceFirst('{name}', 'NeoAssets'),
      confirmLabel: AppLocale.logout.getString(context),
      icon: Symbols.swap_horiz_rounded,
    );
    if (confirmed != true || !mounted) return;
    await MetadataProviderService.signOut(MetadataProviderKind.neoAssets);
    if (!mounted) return;
    setState(() {
      _mode = _Mode.chooser;
      _choice = 0;
    });
  }

  void _onScreenScraperSignedOut() {
    if (!mounted) return;
    setState(() {
      _mode = _Mode.chooser;
      _choice = 0;
    });
  }

  // ==========================================
  // BUILD
  // ==========================================

  @override
  Widget build(BuildContext context) {
    switch (_mode) {
      case _Mode.loading:
        return const Center(child: CircularProgressIndicator());
      case _Mode.screenScraper:
        return ScreenScraperSettingsContent(
          key: _screenScraperKey,
          isContentFocused: widget.isContentFocused,
          onSignedOut: _onScreenScraperSignedOut,
        );
      case _Mode.neoAssets:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(title: AppLocale.metadata.getString(context)),
            SizedBox(height: 12.r),
            Expanded(
              child: NeoAssetsSettingsContent(
                key: _neoAssetsKey,
                isContentFocused: widget.isContentFocused,
                onSignedOut: _leaveNeoAssets,
              ),
            ),
          ],
        );
      case _Mode.chooser:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(title: AppLocale.metadata.getString(context)),
            SizedBox(height: 12.r),
            Expanded(child: _buildChooser(context)),
          ],
        );
    }
  }

  Widget _buildChooser(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: 4.r, bottom: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.chooseMetadataProvider.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 12.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 2.r),
          Text(
            AppLocale.chooseMetadataProviderSub.getString(context),
            style: TextStyle(fontSize: 8.r, color: muted),
          ),
          SizedBox(height: 8.r),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 1,
                  child: _ProviderCard(
                    focused: widget.isContentFocused && _choice == 0,
                    recommended: true,
                    accent: NeoAssetsBrand.accent(context),
                    logo: const NeoAssetsBadge(size: 34),
                    name: 'NeoAssets',
                    tagline: AppLocale.neoAssetsTagline.getString(context),
                    actionLabel: AppLocale.neoAssetsConnect.getString(context),
                    onTap: () => _choose(MetadataProviderKind.neoAssets),
                  ),
                ),
                SizedBox(width: 10.r),
                Expanded(
                  flex: 1,
                  child: _ProviderCard(
                    focused: widget.isContentFocused && _choice == 1,
                    recommended: false,
                    accent: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    logo: _ScreenScraperBadge(color: muted),
                    name: 'ScreenScraper',
                    tagline: AppLocale.screenScraperTagline.getString(context),
                    actionLabel: AppLocale.screenScraperLogin.getString(
                      context,
                    ),
                    onTap: () => _choose(MetadataProviderKind.screenScraper),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 8.r),
          _ComparisonTable(),
          SizedBox(height: 8.r),
          Row(
            children: [
              Icon(Symbols.info_rounded, size: 12.r, color: muted),
              SizedBox(width: 6.r),
              Expanded(
                child: Text(
                  AppLocale.metadataProviderOneSession.getString(context),
                  style: TextStyle(fontSize: 8.r, color: muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScreenScraperBadge extends StatelessWidget {
  final Color color;

  const _ScreenScraperBadge({required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: 34.r,
    height: 34.r,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10.r),
      color: color.withValues(alpha: 0.12),
    ),
    child: Icon(Symbols.travel_explore_rounded, size: 18.r, color: color),
  );
}

class _ProviderCard extends StatelessWidget {
  final bool focused;
  final bool recommended;
  final Color accent;
  final Widget logo;
  final String name;
  final String tagline;
  final String actionLabel;
  final VoidCallback onTap;

  const _ProviderCard({
    required this.focused,
    required this.recommended,
    required this.accent,
    required this.logo,
    required this.name,
    required this.tagline,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onCard = theme.colorScheme.onSurface;
    return InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(14.r),
      onTap: () {
        SfxService().playNavSound();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.all(10.r),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14.r),
          gradient: recommended
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    NeoAssetsBrand.accent(context).withValues(alpha: 0.18),
                    NeoAssetsBrand.secondary(context).withValues(alpha: 0.08),
                  ],
                )
              : null,
          color: recommended ? null : theme.cardColor.withValues(alpha: 0.25),
          border: Border.all(
            color: focused
                ? accent
                : accent.withValues(alpha: recommended ? 0.35 : 0.15),
            width: focused ? 2.r : 1.r,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.3),
                    blurRadius: 12.r,
                    spreadRadius: 1.r,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                logo,
                SizedBox(width: 10.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 13.r,
                          fontWeight: FontWeight.bold,
                          color: onCard,
                        ),
                      ),
                      Text(
                        tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 8.r,
                          color: onCard.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (recommended)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 7.r,
                      vertical: 3.r,
                    ),
                    decoration: BoxDecoration(
                      color: NeoAssetsBrand.accent(context),
                      borderRadius: BorderRadius.circular(999.r),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.star_rounded,
                          size: 9.r,
                          fill: 1,
                          color: NeoAssetsBrand.onAccent(context),
                        ),
                        SizedBox(width: 3.r),
                        Text(
                          AppLocale.recommended.getString(context),
                          style: TextStyle(
                            fontSize: 7.r,
                            fontWeight: FontWeight.w800,
                            color: NeoAssetsBrand.onAccent(context),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            SizedBox(height: 10.r),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: 7.r),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                color: focused
                    ? (recommended ? NeoAssetsBrand.accent(context) : onCard)
                    : (recommended
                          ? NeoAssetsBrand.accent(context)
                                .withValues(alpha: 0.15)
                          : onCard.withValues(alpha: 0.06)),
              ),
              child: Text(
                actionLabel,
                style: TextStyle(
                  fontSize: 10.r,
                  fontWeight: FontWeight.bold,
                  color: focused
                      ? (recommended
                            ? NeoAssetsBrand.onAccent(context)
                            : theme.colorScheme.surface)
                      : (recommended ? NeoAssetsBrand.ink(context) : onCard),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Side-by-side differences between the two providers.
class _ComparisonTable extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final rows = <(String, String, String)>[
      (
        AppLocale.compareMatching,
        AppLocale.compareMatchingNeoAssets,
        AppLocale.compareMatchingScreenScraper,
      ),
      (
        AppLocale.compareLanguages,
        AppLocale.compareLanguagesNeoAssets,
        AppLocale.compareLanguagesScreenScraper,
      ),
      (
        AppLocale.compareDownloads,
        AppLocale.compareDownloadsNeoAssets,
        AppLocale.compareDownloadsScreenScraper,
      ),
      (
        AppLocale.compareQuota,
        AppLocale.compareQuotaNeoAssets,
        AppLocale.compareQuotaScreenScraper,
      ),
      (
        AppLocale.compareSignIn,
        AppLocale.compareSignInNeoAssets,
        AppLocale.compareSignInScreenScraper,
      ),
    ];
    TextStyle cell(Color color, {bool bold = false}) => TextStyle(
      fontSize: 8.r,
      color: color,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
    );
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: onSurface.withValues(alpha: 0.08)),
      ),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(3),
          1: FlexColumnWidth(4),
          2: FlexColumnWidth(4),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              Padding(
                padding: EdgeInsets.only(bottom: 4.r),
                child: Text(
                  'NeoAssets',
                  style: cell(NeoAssetsBrand.ink(context), bold: true),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: 4.r),
                child: Text(
                  'ScreenScraper',
                  style: cell(onSurface.withValues(alpha: 0.6), bold: true),
                ),
              ),
            ],
          ),
          for (final (label, neo, ss) in rows)
            TableRow(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: onSurface.withValues(alpha: 0.06)),
                ),
              ),
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 4.r),
                  child: Text(
                    label.getString(context),
                    style: cell(onSurface.withValues(alpha: 0.55)),
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      Symbols.check_rounded,
                      size: 10.r,
                      color: NeoAssetsBrand.ink(context),
                    ),
                    SizedBox(width: 3.r),
                    Expanded(
                      child: Text(
                        neo.getString(context),
                        style: cell(onSurface.withValues(alpha: 0.9)),
                      ),
                    ),
                  ],
                ),
                Text(
                  ss.getString(context),
                  style: cell(onSurface.withValues(alpha: 0.6)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
