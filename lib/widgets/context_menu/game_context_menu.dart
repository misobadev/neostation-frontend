import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';

/// One membership bucket a game can belong to, as presented by the Y menu.
///
/// The menu itself is membership-agnostic: the caller supplies the buckets and
/// the callback that mutates them, so Favourites (backed by
/// `user_roms.is_favorite`) and user collections can sit side by side without
/// the menu knowing the difference.
class GameContextMenuTarget {
  /// Stable identifier, unique within one menu (e.g. `favorites`).
  final String id;

  /// Already-localized display name.
  final String label;

  final IconData icon;

  /// Whether the game is currently in this bucket. Seeds the checkbox; the
  /// menu owns the state from then on.
  final bool isMember;

  /// Puts the game in the bucket, or takes it out, and reports whether the
  /// change stuck. Returning false reverts the checkbox the menu already
  /// flipped.
  final Future<bool> Function(bool member) setMember;

  const GameContextMenuTarget({
    required this.id,
    required this.label,
    required this.icon,
    required this.isMember,
    required this.setMember,
  });
}

const String _settingsId = 'settings';
const String _createId = 'create';
const String _scrapeId = 'scrape';
const String _viewModeId = 'view_mode';
const String _randomId = 'random';
const String _searchId = 'search';
const String _togglePrefix = 'toggle:';

/// Opens the per-game Y menu anchored to [anchorKey]'s widget.
///
/// The menu shows `Settings`, `Scrape`, and one `Add to…` row holding **every**
/// bucket as a checkbox — Favourites and each collection, in or out, all in one
/// list. `Settings` is the row the cursor starts on: it is the one action every
/// game has, and the one the menu is most often opened for.
///
/// The checklist replaced a split into `Add to…` and `Remove from…`. That split
/// sorted each bucket by the game's state, so Favourites sat under a different
/// parent for the very next game and no press was ever twice in the same place;
/// an empty half was dropped entirely, which shifted the rows below it too. It
/// also cost one whole visit per bucket, because activating a row closed the
/// menu — putting a game in three collections meant opening the menu three
/// times. The checklist toggles in place and stays open, so position is fixed
/// and a run of changes is one visit.
///
/// [onCreateTarget] adds a trailing `New collection…` row to the checklist. It
/// is the seam collections plug into, and it is the one row there that still
/// closes the menu: it is an action rather than a membership, and the hairline
/// above it says so.
///
/// [onScrape] sits with `Settings` rather than with the view-level actions
/// below, because like `Settings` it acts on this one game. The host leaves it
/// unbound for a game that cannot be scraped at all — one whose own system has
/// no ScreenScraper mapping — so the row is absent rather than present and
/// silently inert.
///
/// [onViewMode] and [onRandom] are the view-level actions that used to live on
/// the vertical action rail. They are grouped below the membership row,
/// separated from it, and each is omitted when the host has nothing to bind —
/// the menu is the only route to them for a user without a gamepad.
///
/// [onSearch] opens the library search from the same view-level group. It
/// leads the group because it is the one row there that leaves this view.
Future<void> showGameContextMenu({
  required BuildContext context,
  required List<GameContextMenuTarget> targets,
  required VoidCallback onSettings,
  GlobalKey? anchorKey,
  Future<void> Function()? onCreateTarget,
  String? createTargetLabel,
  VoidCallback? onScrape,
  VoidCallback? onViewMode,
  VoidCallback? onRandom,
  VoidCallback? onSearch,
}) async {
  assert(
    onCreateTarget == null || createTargetLabel != null,
    'createTargetLabel is required when onCreateTarget is supplied',
  );

  final membershipChildren = <ContextMenuItem>[
    for (final target in targets)
      ContextMenuItem(
        id: '$_togglePrefix${target.id}',
        label: target.label,
        icon: target.icon,
        checkable: true,
        selected: target.isMember,
      ),
    if (onCreateTarget != null)
      ContextMenuItem(
        id: _createId,
        label: createTargetLabel ?? '',
        icon: Symbols.add_rounded,
        separatorBefore: targets.isNotEmpty,
      ),
  ];

  final items = <ContextMenuItem>[
    ContextMenuItem(
      id: _settingsId,
      label: AppLocale.gameSettings.getString(context),
      icon: Symbols.settings_rounded,
    ),
    if (onScrape != null)
      ContextMenuItem(
        id: _scrapeId,
        label: AppLocale.hintScrape.getString(context),
        icon: Symbols.cloud_download_rounded,
      ),
    if (membershipChildren.isNotEmpty)
      ContextMenuItem(
        id: 'add',
        label: AppLocale.addTo.getString(context),
        icon: Symbols.playlist_add_rounded,
        children: membershipChildren,
      ),
    // View-level actions. The hairline marks where the menu stops acting on
    // this one game and starts acting on the whole view.
    if (onSearch != null)
      ContextMenuItem(
        id: _searchId,
        label: AppLocale.searchTitle.getString(context),
        icon: Symbols.search_rounded,
        separatorBefore: true,
      ),
    if (onViewMode != null)
      ContextMenuItem(
        id: _viewModeId,
        label: AppLocale.viewMode.getString(context),
        icon: Symbols.grid_view_rounded,
        separatorBefore: onSearch == null,
      ),
    if (onRandom != null)
      ContextMenuItem(
        id: _randomId,
        label: AppLocale.randomGame.getString(context),
        icon: Symbols.casino_rounded,
        separatorBefore: onSearch == null && onViewMode == null,
      ),
  ];

  final result = await showAnchoredContextMenu(
    context: context,
    items: items,
    anchorKey: anchorKey,
    // The anchor is a whole list row / grid card, so the menu starts at its
    // left edge instead of past its right one — which leaves the room the
    // `Add to…` checklist needs on the right.
    alignment: ContextMenuAlignment.overAnchor,
    layerId: 'game_context_menu',
    submenuLayerId: 'game_context_submenu',
    onToggle: (String id, {required bool checked}) async {
      if (!id.startsWith(_togglePrefix)) return true;
      final target = _targetById(targets, id.substring(_togglePrefix.length));
      if (target == null) return true;
      return target.setMember(checked);
    },
  );

  // Memberships resolved through [onToggle] while the menu was open, so
  // anything that comes back here is one of the leaves.
  if (result == null) return;

  if (result == _settingsId) {
    onSettings();
    return;
  }
  if (result == _scrapeId) {
    onScrape?.call();
    return;
  }
  if (result == _createId) {
    await onCreateTarget?.call();
    return;
  }
  if (result == _searchId) {
    onSearch?.call();
    return;
  }
  if (result == _viewModeId) {
    onViewMode?.call();
    return;
  }
  if (result == _randomId) {
    onRandom?.call();
  }
}

GameContextMenuTarget? _targetById(
  List<GameContextMenuTarget> targets,
  String id,
) {
  for (final target in targets) {
    if (target.id == id) return target;
  }
  return null;
}
