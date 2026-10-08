import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// A single row of an [showAnchoredContextMenu] menu.
///
/// An item is either a leaf (activating it pops the whole menu stack with its
/// [id]) or a parent with [children] (activating it opens one submenu level).
/// The widget deliberately knows nothing about games, collections or any other
/// domain concept: callers build the item list and interpret the returned id.
class ContextMenuItem {
  /// Value returned by [showAnchoredContextMenu] when this leaf is activated.
  final String id;

  /// Already-localized row label. Nothing here goes through `AppLocale`, so the
  /// caller is responsible for translating before building the list.
  final String label;

  /// Optional leading glyph.
  final IconData? icon;

  /// Sub-items. A non-empty list turns this row into a submenu parent (only one
  /// level deep is supported: children of children are ignored).
  final List<ContextMenuItem> children;

  /// Draws a hairline above the row, to group it apart from the rows before it.
  final bool separatorBefore;

  /// Marks the row as the value currently in effect, drawing a trailing check.
  ///
  /// For rows that pick a setting rather than perform an action (view mode,
  /// card size), so the menu shows what is active the way the systems and
  /// game-view dropdowns do. Ignored on a submenu parent, whose trailing slot
  /// already carries the chevron.
  ///
  /// On a [checkable] row this seeds the checkbox instead: the menu owns the
  /// state from then on.
  final bool selected;

  /// Marks the row as a membership toggle rather than an action.
  ///
  /// Activating it flips its checkbox where it stands and leaves the menu open,
  /// so several buckets can be changed in one visit, and reports the change
  /// through [AnchoredContextMenu.onToggle] instead of popping the stack with
  /// [id]. The trailing slot draws a box rather than a bare tick, because the
  /// difference that matters to the reader is that the row can be pressed
  /// again.
  ///
  /// A checkable row's position never depends on its own state, which is the
  /// point: the alternative — sorting members into one submenu and non-members
  /// into another — moves a bucket every time it is used, so no press is ever
  /// in the same place twice.
  final bool checkable;

  const ContextMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.children = const <ContextMenuItem>[],
    this.separatorBefore = false,
    this.selected = false,
    this.checkable = false,
  });

  bool get hasSubmenu => children.isNotEmpty;
}

/// Applies a [ContextMenuItem.checkable] row's change, returning whether it
/// stuck.
///
/// Returning false reverts the checkbox the menu already flipped, so a write
/// that failed never leaves the menu claiming it succeeded. The menu is
/// optimistic on purpose: a checkbox that waited for a database round trip
/// would lag every press.
typedef ContextMenuToggle =
    Future<bool> Function(String id, {required bool checked});

/// Which edge of the anchor the panel hangs off.
enum ContextMenuAlignment {
  /// Centre the entire panel in the viewport for a standalone chooser.
  centerScreen,

  /// Panel starts just past the anchor's right edge. Right for a small anchor
  /// (an options button), where the menu should sit next to it.
  besideAnchor,

  /// Panel's left edge lines up with the anchor's. Right for a wide anchor (a
  /// full-width list row, a grid card), where [besideAnchor] would shove the
  /// panel to the far side of the screen and leave no room for a submenu.
  overAnchor,
}

/// Sentinel result meaning "the user asked to close the whole stack" (Y).
/// A submenu pops with it so the parent level closes itself too.
const String _dismissAllResult = '__context_menu_dismiss_all__';

/// Row metrics. Kept as constants so the menu box can be measured before it is
/// laid out — the viewport clamp/flip needs a height up front.
const double _kItemHeight = 30;
const double _kSeparatorHeight = 9;
const double _kVerticalPadding = 8;
const double _kAnchorGap = 6;
const double _kViewportMargin = 8;

/// Opens a gamepad-navigable context menu anchored to [anchorKey]'s widget.
///
/// Returns the [ContextMenuItem.id] of the activated leaf, or null when the
/// menu was dismissed. [anchorKey] may be null or unmounted — the menu then
/// falls back to the centre of the screen.
///
/// [initialIndex] pre-highlights a top-level row. When [openSubmenuAtIndex] is
/// given, that row's submenu is opened as soon as the menu appears, with
/// [initialSubmenuIndex] highlighted inside it, so a two-press shortcut
/// (open + activate) can land on a nested item.
///
/// [onToggle] receives every [ContextMenuItem.checkable] row's change. Those
/// rows do not resolve the menu, so a menu built only from them returns null
/// however much the user changed with it.
///
/// Each level pushes its own [GamepadNavigationManager] layer ([layerId] /
/// [submenuLayerId]) and pops it in `dispose`, so app resume re-activates the
/// top-most menu rather than the screen buried under it.
Future<String?> showAnchoredContextMenu({
  required BuildContext context,
  required List<ContextMenuItem> items,
  GlobalKey? anchorKey,
  int initialIndex = 0,
  int? openSubmenuAtIndex,
  int initialSubmenuIndex = 0,
  double? width,
  ContextMenuAlignment alignment = ContextMenuAlignment.besideAnchor,
  String layerId = 'context_menu',
  String submenuLayerId = 'context_submenu',
  ContextMenuToggle? onToggle,
}) async {
  if (items.isEmpty) return null;

  final Rect anchor = _resolveAnchorRect(anchorKey, context);

  final result = await showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: layerId,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return FadeTransition(
        opacity: animation,
        child: AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          initialIndex: initialIndex,
          openSubmenuAtIndex: openSubmenuAtIndex,
          initialSubmenuIndex: initialSubmenuIndex,
          width: width,
          alignment: alignment,
          layerId: layerId,
          submenuLayerId: submenuLayerId,
          onToggle: onToggle,
        ),
      );
    },
  );

  return result == _dismissAllResult ? null : result;
}

/// Global bounds of [anchorKey]'s render box, or a zero-size rect at the centre
/// of the screen when the key has no (attached) render object — which happens
/// when the anchored row has been scrolled out of the viewport.
Rect _resolveAnchorRect(GlobalKey? anchorKey, BuildContext context) {
  final Size screen = MediaQuery.of(context).size;
  final RenderObject? renderObject = anchorKey?.currentContext
      ?.findRenderObject();
  if (renderObject is RenderBox &&
      renderObject.attached &&
      renderObject.hasSize) {
    final Offset origin = renderObject.localToGlobal(Offset.zero);
    if (origin.dx.isFinite && origin.dy.isFinite) {
      return origin & renderObject.size;
    }
  }
  return Rect.fromCenter(
    center: Offset(screen.width / 2, screen.height / 2),
    width: 0,
    height: 0,
  );
}

/// Which way to scroll the panel so the row at [to] comes into view, given the
/// row at [from] that the cursor just left.
///
/// The rule is about the two *indices*, deliberately not about which key was
/// pressed, and the difference is the whole point. Reading the key direction
/// gets a plain step right and the wrap wrong, because the menu's cursor wraps:
/// pressing down on the last row moves to the first, which is a step *up* the
/// list even though the user pressed down. That is not a cosmetic mismatch --
/// [ScrollPositionAlignmentPolicy.keepVisibleAtEnd] refuses to scroll
/// backwards, so asking it to reveal row 0 from the bottom of the list leaves
/// the panel exactly where it was, with the cursor on a row nobody can see.
/// Its counterpart refuses to scroll forwards and strands the other wrap the
/// same way.
///
/// Comparing the indices describes where the cursor actually went, so the wrap
/// needs no special case: it is simply a very long step in the other direction.
/// Either way the panel moves the minimum needed to expose the row's leading or
/// trailing edge, which is what keeps a walk down the list steady instead of
/// recentring under the cursor on every press.
@visibleForTesting
ScrollPositionAlignmentPolicy contextMenuRevealPolicy({
  required int from,
  required int to,
}) => to < from
    ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
    : ScrollPositionAlignmentPolicy.keepVisibleAtEnd;

/// The menu panel itself. Public so a caller can host it directly (e.g. in a
/// test), but the normal entry point is [showAnchoredContextMenu].
class AnchoredContextMenu extends StatefulWidget {
  final List<ContextMenuItem> items;

  /// Global bounds of the widget the menu hangs off.
  final Rect anchorRect;
  final int initialIndex;
  final int? openSubmenuAtIndex;
  final int initialSubmenuIndex;
  final double? width;
  final ContextMenuAlignment alignment;
  final String layerId;
  final String submenuLayerId;

  /// Applies a [ContextMenuItem.checkable] row's change. Shared with every
  /// submenu this panel opens, because the checklist normally lives one level
  /// down from the row that names it.
  final ContextMenuToggle? onToggle;

  /// Whether this panel is a nested level rather than the root menu.
  ///
  /// Only a submenu closes on D-pad left: left is how the user walks back out
  /// of the level right walked into. At the root there is nothing to walk back
  /// to, and closing there made a stray left press dismiss the whole menu, so
  /// the root leaves left unbound — B (or a tap outside) is the way out.
  final bool isSubmenu;

  const AnchoredContextMenu({
    super.key,
    required this.items,
    required this.anchorRect,
    this.initialIndex = 0,
    this.openSubmenuAtIndex,
    this.initialSubmenuIndex = 0,
    this.width,
    this.alignment = ContextMenuAlignment.besideAnchor,
    this.layerId = 'context_menu',
    this.submenuLayerId = 'context_submenu',
    this.onToggle,
    this.isSubmenu = false,
  });

  @override
  State<AnchoredContextMenu> createState() => _AnchoredContextMenuState();
}

class _AnchoredContextMenuState extends State<AnchoredContextMenu> {
  late final GamepadNavigation _gamepadNav;
  late int _selectedIndex;
  bool _submenuOpen = false;

  /// Live checkbox state for every [ContextMenuItem.checkable] row, seeded from
  /// [ContextMenuItem.selected] and owned by the panel from then on. Held here
  /// rather than rebuilt from the caller's items because the items are handed
  /// to `showGeneralDialog` once and never rebuilt: the checklist has to be
  /// able to redraw itself without the menu being torn down and reopened.
  late final Map<String, bool> _checked;

  /// Rows whose [ContextMenuToggle] has not come back yet. A second press on
  /// the same row is dropped rather than queued -- two writes racing on one
  /// bucket can land in either order, and the loser would decide the answer.
  final Set<String> _toggling = <String>{};

  /// One key per row, used to anchor that row's submenu next to it, and to
  /// scroll that row back into view when the cursor walks onto it.
  late final List<GlobalKey> _itemKeys;

  /// Drives the panel's scroll when the list is taller than the viewport.
  ///
  /// The rows are a [Column] inside a [SingleChildScrollView] rather than a
  /// [ListView] on purpose: every row must stay laid out even while scrolled
  /// out of sight, because [_resolveAnchorRect] reads a row's global rect off
  /// its key to place that row's submenu. A lazily-built list would hand back a
  /// null context for exactly the off-screen row whose submenu is being opened.
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
    _selectedIndex = widget.initialIndex.clamp(0, widget.items.length - 1);
    _checked = <String, bool>{
      for (final item in widget.items)
        if (item.checkable) item.id: item.selected,
    };

    _gamepadNav = GamepadNavigation(
      // `Add to` holds one row per collection, so this list is as long as the
      // user has made it and pressing once per row is not a walk anyone should
      // have to do. Held directions stop at the ends rather than spinning the
      // cursor round -- see [_move], which is also where the wrap that a single
      // press still performs lives.
      allowRepeat: true,
      onNavigateUp: (bool repeat) => _move(-1, repeat: repeat),
      onNavigateDown: (bool repeat) => _move(1, repeat: repeat),
      onNavigateRight: _openSubmenuIfAny,
      // Root menu: left is inert (see [AnchoredContextMenu.isSubmenu]).
      onNavigateLeft: widget.isSubmenu ? _close : null,
      onSelectItem: _activate,
      onBack: _close,
      // Y is the button that opened the menu: pressing it again dismisses the
      // whole stack rather than toggling a level.
      onFavorite: _dismissAll,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Dismissed within its first frame (a second B, a tap outside during the
      // fade-in): dispose has already popped the layer, and pushing it now
      // would leave a dead layer on top of the stack eating every button.
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        widget.layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      // The cursor can open deep in the list -- reopening the menu restores
      // the row it was left on -- and on a capped panel that row may start off
      // screen. The panel starts at the top, so every such row is reached by
      // scrolling forwards: -1 is the index before the first.
      _revealSelected(-1);

      final autoOpen = widget.openSubmenuAtIndex;
      if (autoOpen != null &&
          autoOpen >= 0 &&
          autoOpen < widget.items.length &&
          widget.items[autoOpen].hasSubmenu) {
        _openSubmenu(autoOpen, initialIndex: widget.initialSubmenuIndex);
      }
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(widget.layerId);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls the focused row back into view after the cursor moves onto it.
  ///
  /// [previousIndex] is the row the cursor came from; the one it is on now is
  /// [_selectedIndex]. See [contextMenuRevealPolicy] for why the pair is what
  /// decides the alignment, rather than which key was pressed.
  void _revealSelected(int previousIndex, {bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final rowContext = _itemKeys[_selectedIndex].currentContext;
      if (rowContext == null) return;
      Scrollable.ensureVisible(
        rowContext,
        duration: animate ? const Duration(milliseconds: 120) : Duration.zero,
        curve: Curves.easeOut,
        alignmentPolicy: contextMenuRevealPolicy(
          from: previousIndex,
          to: _selectedIndex,
        ),
      );
    });
  }

  /// Moves the cursor by [delta], returning whether it went anywhere.
  ///
  /// The return value is what [GamepadNavigation] reads to decide whether to
  /// keep an auto-repeat running, which is the whole reason a held direction
  /// and a single press differ here: a single press at either end wraps round,
  /// as it always has, but a *held* one stops there. Wrapping under a held
  /// button would send the cursor round the list forever, and on a long list of
  /// collections the user would have no idea which lap they were on.
  bool _move(int delta, {bool repeat = false}) {
    if (widget.items.isEmpty) return false;
    final int previousIndex = _selectedIndex;
    final int next = previousIndex + delta;
    final bool wraps = next < 0 || next >= widget.items.length;
    if (wraps && repeat) return false;

    setState(() {
      _selectedIndex = (next + widget.items.length) % widget.items.length;
    });
    // Repeats ramp to one step every 35ms, far inside the reveal's animation,
    // so an animated scroll would fall behind the cursor and never catch up
    // while the button was held. Under a repeat the panel jumps instead.
    _revealSelected(previousIndex, animate: !repeat);
    SfxService().playNavSound();
    return true;
  }

  void _close() {
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _dismissAll() {
    SfxService().playBackSound();
    Navigator.of(context).pop(_dismissAllResult);
  }

  void _openSubmenuIfAny() {
    if (widget.items[_selectedIndex].hasSubmenu) {
      _openSubmenu(_selectedIndex);
    }
  }

  void _activate() {
    final item = widget.items[_selectedIndex];
    if (item.hasSubmenu) {
      _openSubmenu(_selectedIndex);
      return;
    }
    if (item.checkable) {
      // Deliberately not awaited: the box flips on this frame and the write
      // catches up. B stays live throughout, so a slow write can never trap
      // the user inside the menu.
      unawaited(_toggleChecked(item));
      return;
    }
    SfxService().playEnterSound();
    Navigator.of(context).pop(item.id);
  }

  /// Flips [item]'s checkbox and reports it, reverting if the write did not
  /// stick. The menu stays open either way -- that is the whole difference
  /// between a checkable row and a leaf.
  Future<void> _toggleChecked(ContextMenuItem item) async {
    if (_toggling.contains(item.id)) return;
    final bool next = !(_checked[item.id] ?? item.selected);

    SfxService().playEnterSound();
    setState(() {
      _checked[item.id] = next;
      _toggling.add(item.id);
    });

    final bool applied =
        await widget.onToggle?.call(item.id, checked: next) ?? true;
    if (!mounted) return;

    setState(() {
      _toggling.remove(item.id);
      if (!applied) _checked[item.id] = !next;
    });
  }

  /// Opens [index]'s children as a second level, anchored to that row. The
  /// submenu owns its own nav layer; when it resolves with a leaf id (or the
  /// dismiss-all sentinel) this level closes too, so one activation always
  /// tears the whole stack down.
  Future<void> _openSubmenu(int index, {int initialIndex = 0}) async {
    if (_submenuOpen) return;
    final item = widget.items[index];
    if (!item.hasSubmenu) return;

    setState(() {
      _selectedIndex = index;
      _submenuOpen = true;
    });
    SfxService().playEnterSound();

    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: widget.submenuLayerId,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: AnchoredContextMenu(
            items: item.children,
            anchorRect: _resolveAnchorRect(_itemKeys[index], dialogContext),
            initialIndex: initialIndex,
            width: widget.width,
            layerId: widget.submenuLayerId,
            // One level only: a third level would reuse the same layer id.
            submenuLayerId: widget.submenuLayerId,
            onToggle: widget.onToggle,
            isSubmenu: true,
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _submenuOpen = false);
    if (result != null) {
      Navigator.of(context).pop(result);
    }
  }

  /// Height the panel would occupy if nothing constrained it. Computed from the
  /// row metrics rather than measured, because the viewport clamp has to run
  /// before layout.
  ///
  /// This is a want, not a promise: a long enough list exceeds the screen, and
  /// [build] caps it. Keep the two apart -- placing the panel by this figure
  /// while it renders at the capped one is what put the rows off the bottom of
  /// the screen in the first place.
  double get _panelHeight {
    double height = _kVerticalPadding.r * 2;
    for (final item in widget.items) {
      if (item.separatorBefore) height += _kSeparatorHeight.r;
      height += _kItemHeight.r;
    }
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Size screen = MediaQuery.of(context).size;
    final double width = widget.width ?? 200.r;
    final double margin = _kViewportMargin.r;

    // A menu with more rows than the screen has room for is capped to the
    // viewport and scrolls the remainder. Without this the placement maths
    // below still ran on the full height: every flip overflowed too, the final
    // clamp collapsed to a no-op (`maxTop` floors at zero once the panel is
    // taller than the screen), and the panel was pinned to the top with its
    // tail simply painted past the bottom edge -- unreachable rather than
    // merely awkward. A user with enough collections could not see, let alone
    // pick, the ones at the end of `Add to`.
    final double maxHeight = (screen.height - margin * 2).clamp(
      0.0,
      double.infinity,
    );
    final bool scrolls = _panelHeight > maxHeight;
    final double height = scrolls ? maxHeight : _panelHeight;

    final double gap = _kAnchorGap.r;

    // A row with children opens its submenu to the right, because right is the
    // button the user presses to open it. So the panel is not placed for its
    // own width but for the whole chain's: reserve a second panel beside it
    // whenever any row has a submenu, or the submenu flips back over the menu
    // that spawned it.
    final bool opensSubmenu = widget.items.any((item) => item.hasSubmenu);
    final double chainWidth = opensSubmenu ? width * 2 + gap : width;

    // [ContextMenuAlignment.overAnchor] starts the panel at the anchor's left
    // edge; [besideAnchor] hangs it off the right edge. A full-width list row
    // is metres wide, so hanging off its right edge would put the panel against
    // the far side of the screen with nothing but the margin left for a
    // submenu — which is what overAnchor exists to avoid.
    double left = widget.alignment == ContextMenuAlignment.overAnchor
        ? widget.anchorRect.left
        : widget.anchorRect.right + gap;

    // Flip to the anchor's other side when the panel itself overflows, then
    // pull it back far enough that the submenu fits too. Clamp last, so a very
    // wide card can never push the panel off the edge (the Steam Deck's
    // 1280x800 logical viewport is the tightest).
    if (left + width > screen.width - margin) {
      left = widget.anchorRect.left - width - gap;
    }
    if (left + chainWidth > screen.width - margin) {
      left = screen.width - margin - chainWidth;
    }
    final double maxLeft = (screen.width - width - margin).clamp(
      0.0,
      double.infinity,
    );
    left = left.clamp(margin.clamp(0.0, maxLeft), maxLeft);

    // Vertically: [besideAnchor] sits alongside the anchor, so it top-aligns
    // with it. [overAnchor] shares the anchor's column, so top-aligning would
    // bury the very row the menu was opened on — it drops below the anchor
    // instead, leaving the selected game's name readable above the panel.
    // Either way, flip to the anchor's other side when the panel would run
    // past the bottom, then clamp.
    double top = widget.alignment == ContextMenuAlignment.overAnchor
        ? widget.anchorRect.bottom + gap
        : widget.anchorRect.top;
    if (top + height > screen.height - margin) {
      top = widget.alignment == ContextMenuAlignment.overAnchor
          ? widget.anchorRect.top - height - gap
          : widget.anchorRect.bottom - height;
    }
    // An anchor taller than the room on either side of it puts both of the
    // above out of bounds, and the clamp below would then park the panel
    // against the top of the screen, attached to nothing — the systems
    // carousel's centred card is nearly the full viewport, so it landed on the
    // header. Centre it on the anchor instead: with the panel already sharing
    // the anchor's left edge, that is the one remaining position that still
    // reads as belonging to the card.
    if (top < margin) {
      top = widget.anchorRect.center.dy - height / 2;
    }
    final double maxTop = (screen.height - height - margin).clamp(
      0.0,
      double.infinity,
    );
    top = top.clamp(margin.clamp(0.0, maxTop), maxTop);

    if (widget.alignment == ContextMenuAlignment.centerScreen) {
      left = (screen.width - width) / 2;
      top = (screen.height - height) / 2;
    }

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: _kVerticalPadding.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(
                    alpha: widget.alignment == ContextMenuAlignment.centerScreen
                        ? 0.65
                        : 0.2,
                  ),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              // Bounded by the same figure the placement maths used, less the
              // padding the Container adds around it, so the panel occupies
              // exactly the `height` it was positioned for.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (height - _kVerticalPadding.r * 2).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  // Shown only when there is something to scroll: always-on, a
                  // full-length thumb on a short menu reads as a border.
                  thumbVisibility: scrolls,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: scrolls
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _buildRows(theme),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows(ThemeData theme) {
    final rows = <Widget>[];
    for (int i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (item.separatorBefore) {
        rows.add(
          Divider(
            height: _kSeparatorHeight.r,
            thickness: 1,
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        );
      }
      final bool isFocused = i == _selectedIndex;
      rows.add(
        SizedBox(
          key: _itemKeys[i],
          height: _kItemHeight.r,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4.r),
            child: InkWell(
              onTap: () {
                setState(() => _selectedIndex = i);
                _activate();
              },
              onHover: (hovering) {
                if (hovering && !_submenuOpen) {
                  setState(() => _selectedIndex = i);
                }
              },
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r),
                decoration: BoxDecoration(
                  color: isFocused
                      ? theme.colorScheme.primary.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8.r),
                  border: isFocused
                      ? Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.3,
                          ),
                          width: 1,
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    if (item.icon != null) ...[
                      Icon(
                        item.icon,
                        size: 14.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.9,
                        ),
                      ),
                      SizedBox(width: 8.r),
                    ],
                    Expanded(
                      child: Text(
                        item.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: isFocused
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (item.hasSubmenu)
                      Icon(
                        Symbols.chevron_right_rounded,
                        size: 14.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      )
                    else if (item.checkable)
                      // A box, filled or empty, rather than a tick that is
                      // simply absent: an unchecked row has to read as
                      // something the user can press, and the column of empty
                      // boxes is what says the whole list is a checklist.
                      Icon(
                        _isChecked(item)
                            ? Symbols.check_box_rounded
                            : Symbols.check_box_outline_blank_rounded,
                        size: 14.r,
                        color: _isChecked(item)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.45,
                              ),
                      )
                    else if (item.selected)
                      Icon(
                        Symbols.check_rounded,
                        size: 14.r,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return rows;
  }

  /// Whether [item]'s checkbox is currently ticked. Falls back to the caller's
  /// seed for a row the map has never held (a non-checkable row asked about).
  bool _isChecked(ContextMenuItem item) => _checked[item.id] ?? item.selected;
}
