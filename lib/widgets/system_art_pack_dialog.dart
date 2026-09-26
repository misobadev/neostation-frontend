import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/system_art_pack_tile.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full detail of a system art pack: artwork, description and the gamepad
/// actions to apply it (A) or open the author's support page (X).
///
/// Opened by pressing A (or tapping) a pack in the System Art list. Works with
/// touch and gamepad: A applies/downloads, X opens support, B closes.
class SystemArtPackDialog extends StatefulWidget {
  final NeoAssetsTheme pack;

  const SystemArtPackDialog({super.key, required this.pack});

  static Future<void> show(BuildContext context, NeoAssetsTheme pack) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => SystemArtPackDialog(pack: pack),
    );
  }

  @override
  State<SystemArtPackDialog> createState() => _SystemArtPackDialogState();
}

class _SystemArtPackDialogState extends State<SystemArtPackDialog> {
  late final GamepadNavigation _gamepadNav;
  bool _applying = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: _apply,
      onXButton: _openSupport,
      onBack: () => Navigator.of(context).maybePop(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_art_pack_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('system_art_pack_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _openSupport() {
    final url = widget.pack.donationUrl;
    if (url.isEmpty) return;
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _apply() async {
    if (_applying) return;
    final neoAssets = context.read<NeoAssetsProvider>();

    // Re-applying the pack that is already applied wipes the cache and
    // refetches, which is the repair path for a background that failed to
    // download when the pack was first applied.
    final isActive = neoAssets.isThemeActive(widget.pack.folder);

    final systemFolders = context
        .read<SqliteConfigProvider>()
        .availableSystems
        .where((s) => s.folderName != 'all-background')
        .map((s) => s.folderName)
        .toList();

    setState(() {
      _applying = true;
      _failed = false;
    });

    final applied = await neoAssets.downloadAndApplyTheme(
      widget.pack.folder,
      systemFolders,
      forceRedownload: isActive,
    );

    if (!mounted) return;
    setState(() => _applying = false);
    if (applied) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pack = widget.pack;
    final neoAssets = context.watch<NeoAssetsProvider>();
    final isActive = neoAssets.isThemeActive(pack.folder);
    final downloading = neoAssets.downloading;

    return Dialog(
      backgroundColor: theme.cardColor,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420.r, maxHeight: 560.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16.r, 14.r, 10.r, 8.r),
              child: Row(
                children: [
                  Icon(
                    Symbols.image_rounded,
                    color: theme.colorScheme.primary,
                    size: 18.r,
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      pack.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 14.r,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  if (pack.isAi)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 6.r,
                        vertical: 1.r,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(999.r),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35),
                          width: 1.r,
                        ),
                      ),
                      child: Text(
                        'AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8.r,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(
              height: 1.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            // Foreground download indicator. The pack content can scroll, so
            // the progress lives outside the scroll and stays visible the whole
            // time the pack downloads.
            if (downloading)
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 10.r),
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 16.r,
                          height: 16.r,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.r,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        SizedBox(width: 8.r),
                        Expanded(
                          child: Text(
                            AppLocale.systemArtDownloading.getString(context),
                            style: TextStyle(
                              fontSize: 11.r,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        Text(
                          neoAssets.downloadTotal > 0
                              ? '${(neoAssets.downloadProgress * 100).toInt()}%  '
                                    '(${neoAssets.downloadDone}/${neoAssets.downloadTotal})'
                              : '${(neoAssets.downloadProgress * 100).toInt()}%',
                          style: TextStyle(
                            fontSize: 11.r,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 6.r),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8.r),
                      child: LinearProgressIndicator(
                        value: neoAssets.downloadProgress > 0
                            ? neoAssets.downloadProgress
                            : null,
                        minHeight: 6.r,
                        backgroundColor: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: SystemArtPackMosaic(
                        images: pack.mosaicImages,
                        size: 200,
                      ),
                    ),
                    SizedBox(height: 14.r),
                    Text(
                      [
                        if (pack.author.isNotEmpty)
                          AppLocale.systemArtByAuthor
                              .getString(context)
                              .replaceAll('{author}', pack.author),
                        if (pack.version.isNotEmpty)
                          AppLocale.systemArtVersion
                              .getString(context)
                              .replaceAll('{version}', pack.version),
                      ].join('  ·  '),
                      style: TextStyle(
                        fontSize: 11.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                    SizedBox(height: 8.r),
                    Wrap(
                      spacing: 6.r,
                      runSpacing: 4.r,
                      children: [
                        if (isActive)
                          SystemArtPackChip(
                            icon: Symbols.check_circle_rounded,
                            label: AppLocale.systemArtApplied.getString(
                              context,
                            ),
                          ),
                        if (pack.systemsCovered > 0)
                          SystemArtPackChip(
                            icon: Symbols.devices_rounded,
                            label: AppLocale.systemArtSystemsCovered
                                .getString(context)
                                .replaceAll(
                                  '{count}',
                                  '${pack.systemsCovered}',
                                ),
                          ),
                        if (pack.downloads > 0)
                          SystemArtPackChip(
                            icon: Symbols.download_rounded,
                            label: AppLocale.systemArtDownloads
                                .getString(context)
                                .replaceAll('{count}', '${pack.downloads}'),
                          ),
                      ],
                    ),
                    if (pack.description.isNotEmpty) ...[
                      SizedBox(height: 14.r),
                      Text(
                        pack.description,
                        style: TextStyle(
                          fontSize: 11.r,
                          height: 1.4,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ],
                    if (_failed) ...[
                      SizedBox(height: 12.r),
                      Text(
                        AppLocale.systemArtError.getString(context),
                        style: TextStyle(
                          fontSize: 11.r,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Divider(
              height: 1.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GamepadControl(
                    iconPath: 'assets/images/gamepad/Xbox_A_button.png',
                    label:
                        (isActive
                                ? AppLocale.systemArtApplied
                                : AppLocale.apply)
                            .getString(context),
                    onTap: _applying ? null : _apply,
                    busy: downloading,
                    backgroundColor: theme.colorScheme.primary,
                    textColor: theme.colorScheme.onPrimary,
                  ),
                  if (pack.donationUrl.isNotEmpty) ...[
                    SizedBox(width: 8.r),
                    GamepadControl(
                      iconPath: 'assets/images/gamepad/Xbox_X_button.png',
                      label: AppLocale.systemArtSupport.getString(context),
                      onTap: _openSupport,
                    ),
                  ],
                  SizedBox(width: 8.r),
                  GamepadControl(
                    iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                    label: AppLocale.close.getString(context),
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
