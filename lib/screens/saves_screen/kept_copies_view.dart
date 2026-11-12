import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_shared.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/kept_save_copies.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/custom_folder_upload_prompt.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/neo_glass.dart';

/// The kept copies of saves for the active save provider: one game's (from
/// the game's Manage tab) or every game's (from the NeoSync dashboard). A
/// copy can be restored as its save (A) or deleted (X); B goes back.
class KeptCopiesView extends StatefulWidget {
  const KeptCopiesView({
    super.key,
    this.game,
    required this.onBack,
    this.copies,
    this.inDialog = false,
  });

  /// The game whose copies are listed, or null for every game's.
  final GameModel? game;
  final VoidCallback onBack;

  /// Where the copies come from; built from the app's providers when null.
  final KeptSaveCopies? copies;

  /// Laid out for a dialog rather than a NeoSync dashboard section.
  final bool inDialog;

  /// Opens [game]'s kept copies in a dialog. Completes when it is closed.
  static Future<void> showForGame(BuildContext context, GameModel game) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => KeptCopiesView(
          game: game,
          inDialog: true,
          onBack: () => Navigator.of(dialogContext).pop(),
        ),
      );

  @override
  State<KeptCopiesView> createState() => _KeptCopiesViewState();
}

class _KeptCopiesViewState extends State<KeptCopiesView> {
  static final _log = LoggerService.instance;
  static const String _layerId = 'kept_copies_view';

  late final KeptSaveCopies _copies;
  late final GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};

  List<KeptSaveGroup> _groups = const [];
  List<(KeptSaveGroup, KeptSaveCopy)> _rows = const [];
  int _selected = 0;
  bool _loading = true;
  bool _working = false;

  (KeptSaveGroup, KeptSaveCopy)? get _current =>
      _rows.isEmpty ? null : _rows[_selected.clamp(0, _rows.length - 1)];

  @override
  void initState() {
    super.initState();
    _copies = widget.copies ?? KeptSaveCopies(context.read<NeoSyncProvider>());
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (_) => _move(-1),
      onNavigateDown: (_) => _move(1),
      onSelectItem: _restore,
      onXButton: _delete,
      onBack: _back,
      // As a dashboard section, L1/R1 switch the app's tabs, as from the
      // dashboard's other sections; a dialog keeps them.
      onPreviousTab: widget.inDialog ? null : AppNavigation.previousTab,
      onNextTab: widget.inDialog ? null : AppNavigation.nextTab,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
    _load();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<KeptSaveGroup> groups;
    try {
      final game = widget.game;
      groups = game == null ? await _copies.all() : await _copies.forGame(game);
    } catch (e) {
      _log.e('Listing kept save copies failed: $e');
      groups = const [];
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _rows = [
        for (final group in groups)
          for (final copy in group.copies) (group, copy),
      ];
      _selected = _rows.isEmpty ? 0 : _selected.clamp(0, _rows.length - 1);
      _loading = false;
    });
  }

  void _back() {
    if (_working) return;
    widget.onBack();
  }

  void _move(int delta) {
    if (_rows.isEmpty) return;
    final next = (_selected + delta).clamp(0, _rows.length - 1);
    if (next == _selected) return;
    SfxService().playNavSound();
    setState(() => _selected = next);
    _scrollToSelected();
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys[_selected]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    });
  }

  /// Shows the text of the AppLocale [key], if the view is still there.
  void _notify(String key, NotificationType type) {
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      key.getString(context),
      type: type,
    );
  }

  static String _refusalKey(KeptCopyRefusal reason) => switch (reason) {
    KeptCopyRefusal.gameRunning => AppLocale.keptCopyCloseGame,
    KeptCopyRefusal.syncing => AppLocale.keptCopyWaitForSync,
  };

  Future<void> _restore() async {
    final current = _current;
    if (_working || current == null) return;
    final (group, copy) = current;
    if (copy.sameAsSave) return;
    final refusal = _copies.whyNotNow(widget.game, copy.path);
    if (refusal != null) {
      _notify(_refusalKey(refusal), NotificationType.error);
      return;
    }
    // Held while the question is open too, so a second press can't ask again.
    setState(() => _working = true);
    var body = AppLocale.keptCopyRestoreBody
        .getString(context)
        .replaceFirst('{file}', p.basename(group.savePath));
    if (isSharedMemoryCard(group.savePath)) {
      body = '$body\n\n${AppLocale.keptCopySharedCard.getString(context)}';
    }
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.keptCopyRestoreTitle.getString(context),
      body: body,
      confirmLabel: AppLocale.keptCopyRestore.getString(context),
      icon: Symbols.restore_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
      maxWidth: 360.r,
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _working = false);
      return;
    }
    try {
      await _copies.restore(copy.path, game: widget.game);
      _notify(AppLocale.keptCopyRestored, NotificationType.success);
    } on KeptCopyRefused catch (e) {
      _notify(_refusalKey(e.reason), NotificationType.error);
    } catch (e) {
      _log.e('Restoring ${copy.path} failed: $e');
      _notify(AppLocale.keptCopyRestoreFailed, NotificationType.error);
    }
    await _load();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _delete() async {
    final current = _current;
    if (_working || current == null) return;
    final (_, copy) = current;
    setState(() => _working = true);
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.keptCopyDeleteTitle.getString(context),
      body: AppLocale.keptCopyDeleteBody
          .getString(context)
          .replaceFirst('{file}', p.basename(copy.path)),
      confirmLabel: AppLocale.delete.getString(context),
      icon: Symbols.delete_rounded,
      maxWidth: 360.r,
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _working = false);
      return;
    }
    try {
      await _copies.delete(copy.path);
    } catch (e) {
      _log.e('Deleting ${copy.path} failed: $e');
      _notify(AppLocale.keptCopyDeleteFailed, NotificationType.error);
    }
    await _load();
    if (mounted) setState(() => _working = false);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final content = Column(
      children: [
        NeoSyncSectionHeader(
          icon: Symbols.history_rounded,
          title: AppLocale.keptCopiesTitle.getString(context),
          subtitle:
              widget.game?.name ??
              AppLocale.keptCopiesSubtitle.getString(context),
        ),
        SizedBox(height: 8.r),
        Expanded(
          child: NeoGlassRim(
            cornerRadius: radii.radiusExternalRadius,
            child: Container(
              padding: EdgeInsets.all(8.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: radii.radiusExternal,
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.15),
                ),
              ),
              child: _buildList(theme),
            ),
          ),
        ),
        SizedBox(height: 8.r),
        _buildFooter(theme),
      ],
    );

    if (!widget.inDialog) {
      return Padding(
        padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
        child: content,
      );
    }
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: theme.cardColor,
      insetPadding: EdgeInsets.all(24.r),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Container(
        width: size.width * 0.7,
        height: size.height * 0.8,
        padding: EdgeInsets.all(12.r),
        child: content,
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 20.r,
          height: 20.r,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary,
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          AppLocale.keptCopiesNone.getString(context),
          style: TextStyle(
            fontSize: 11.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    final children = <Widget>[];
    var index = 0;
    for (final group in _groups) {
      children.add(_buildSaveHeader(theme, group));
      for (final copy in group.copies) {
        final rowIndex = index++;
        children.add(
          _buildCopyRow(
            theme,
            rowIndex,
            copy,
            seconds: _sharesMinute(group, copy),
          ),
        );
      }
    }
    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildSaveHeader(ThemeData theme, KeptSaveGroup group) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.65);
    final saveLine = group.saveExists
        ? AppLocale.keptCopyCurrentSave
              .getString(context)
              .replaceFirst('{size}', formatByteSize(group.saveSize!))
              .replaceFirst('{date}', formatKeptCopyDate(group.saveModified!))
        : AppLocale.keptCopyNoCurrentSave.getString(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(4.r, 6.r, 4.r, 4.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.basename(group.savePath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 2.r),
          Text(
            widget.game == null
                ? '$saveLine · ${p.dirname(group.savePath)}'
                : saveLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.r, color: muted),
          ),
        ],
      ),
    );
  }

  String _sourceText(KeptCopySource source) => switch (source) {
    KeptCopySource.otherDevice => AppLocale.keptCopyFromOtherDevice,
    KeptCopySource.beforeDownload => AppLocale.keptCopyBeforeDownload,
    KeptCopySource.serverConflict => AppLocale.keptCopyFromServer,
    KeptCopySource.replaced => AppLocale.keptCopyReplaced,
  }.getString(context);

  /// Whether another copy of [group]'s save was made in the same minute as
  /// [copy], so the two rows would read alike without seconds.
  static bool _sharesMinute(KeptSaveGroup group, KeptSaveCopy copy) {
    final minute = formatKeptCopyDate(copy.date);
    return group.copies.any(
      (other) =>
          !identical(other, copy) && formatKeptCopyDate(other.date) == minute,
    );
  }

  Widget _buildCopyRow(
    ThemeData theme,
    int index,
    KeptSaveCopy copy, {
    bool seconds = false,
  }) {
    final selected = index == _selected;
    // The copy's date leads (for another device's copy, when that device
    // saved it); where it came from goes beneath it.
    final detail = [
      _sourceText(copy.source),
      formatByteSize(copy.size),
      if (copy.sameAsSave) AppLocale.keptCopySameAsSave.getString(context),
    ].join(' · ');
    return Padding(
      key: _rowKeys.putIfAbsent(index, () => GlobalKey()),
      padding: EdgeInsets.only(bottom: 4.r),
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          setState(() => _selected = index);
        },
        borderRadius: BorderRadius.circular(6.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6.r),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2.r,
            ),
          ),
          child: Row(
            children: [
              Icon(
                copy.sameAsSave
                    ? Symbols.check_circle_rounded
                    : Symbols.save_rounded,
                size: 14.r,
                color: theme.colorScheme.primary,
              ),
              SizedBox(width: 8.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatKeptCopyDate(copy.date, seconds: seconds),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.r,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 2.r),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.65,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final current = _current;
    final canRestore = !_working && current != null && !current.$2.sameAsSave;
    final canDelete = !_working && current != null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GamepadControl(
          label: AppLocale.keptCopyRestore.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_A_button.png',
          onTap: canRestore ? _restore : null,
          textColor: theme.colorScheme.onTertiaryFixed,
          backgroundColor: theme.colorScheme.tertiaryFixed,
        ),
        SizedBox(width: 8.r),
        GamepadControl(
          label: AppLocale.delete.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_X_button.png',
          onTap: canDelete ? _delete : null,
          textColor: theme.colorScheme.onTertiaryFixed,
          backgroundColor: theme.colorScheme.tertiaryFixed,
        ),
        SizedBox(width: 8.r),
        NeoSyncBackButton(onTap: _back),
      ],
    );
  }
}

/// A kept copy's date as the list shows it: local time, `YYYY-MM-DD HH:MM`,
/// with `:SS` when [seconds] (copies of a save made in the same minute).
String formatKeptCopyDate(DateTime date, {bool seconds = false}) {
  final t = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final minute =
      '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  return seconds ? '$minute:${two(t.second)}' : minute;
}
