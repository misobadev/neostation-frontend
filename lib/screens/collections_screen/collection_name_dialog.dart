import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

import '../../themes/corner_radii.dart';

/// Makes the prompt numeric: a number keyboard, and D-pad left/right on the
/// unfocused field steps the value by [step] within [min]..[max], starting
/// from [start] when the field is empty. The keyboard stays available with A.
class NumberStepper {
  final num step;
  final num min;
  final num? max;
  final num start;

  /// Whether the value may have a fractional part (number keyboard with a
  /// decimal separator).
  final bool decimal;

  const NumberStepper({
    required this.step,
    required this.min,
    this.max,
    required this.start,
    this.decimal = false,
  });
}

/// Gamepad-navigable single-field text prompt, used to name a collection on
/// creation and to rename one afterwards.
///
/// There is no in-app soft keyboard in NeoStation: text entry is a real
/// [TextField] driven by the platform IME on Android and by the physical
/// keyboard on desktop, exactly as the search screen does it. What the gamepad
/// contributes is the way in and the way out.
///
/// The field, `Cancel` and the confirm button are three focus stops moved
/// between with the D-pad. While the field holds focus:
/// * **B unfocuses it** rather than closing the dialog — the app-wide way out
///   of a text field (a second B then closes the dialog);
/// * **the D-pad does nothing**, so a stray direction can never escape a field
///   the user is still typing in. On Android the translator already withholds
///   everything but B/LB/RB while typing; the explicit guard makes desktop and
///   Android behave the same.
class CollectionNameDialog extends StatefulWidget {
  /// Dialog heading (e.g. "New collection" / "Rename collection").
  final String title;

  /// Text the field opens with, pre-selected so typing replaces it.
  final String initialValue;

  /// Label of the confirming button.
  final String confirmLabel;

  /// Placeholder shown while the field is empty; defaults to "Collection
  /// name".
  final String? hintText;

  /// Turns the prompt into a numeric one; see [NumberStepper].
  final NumberStepper? stepper;

  const CollectionNameDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.confirmLabel,
    this.hintText,
    this.stepper,
  });

  /// Shows the prompt and resolves to the trimmed name, or null when the user
  /// cancelled or left the field empty.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String initialValue,
    required String confirmLabel,
    String? hintText,
    NumberStepper? stepper,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CollectionNameDialog(
        title: title,
        initialValue: initialValue,
        confirmLabel: confirmLabel,
        hintText: hintText,
        stepper: stepper,
      ),
    );
  }

  @override
  State<CollectionNameDialog> createState() => _CollectionNameDialogState();
}

/// The dialog's three focus stops, in D-pad order.
enum _NameDialogStop { field, cancel, confirm }

class _CollectionNameDialogState extends State<CollectionNameDialog> {
  /// Per-instance layer id. [GamepadNavigationManager.popLayer] resolves an id
  /// to the *first* match, so a shared constant would let a second copy of this
  /// dialog unregister the first one's layer and strand its own.
  static int _navLayerSeq = 0;
  late final String _navLayerId = 'collection_name_dialog#${++_navLayerSeq}';

  late final TextEditingController _controller;
  final FocusNode _nameFocus = FocusNode();
  late final GamepadNavigation _gamepadNav;

  _NameDialogStop _stop = _NameDialogStop.field;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialValue.length,
    );

    _gamepadNav = GamepadNavigation(
      // Three fixed stops: a held direction would only spin the cursor round.
      allowRepeat: false,
      onNavigateLeft: () => _horizontal(-1),
      onNavigateRight: () => _horizontal(1),
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _activate,
      onBack: _handleBack,
      // Escape is the desktop cancel; it never reaches here while the field is
      // focused, which is why B is the documented way out of one.
      onSettings: _cancel,
      isTextFieldFocused: () => _nameFocus.hasFocus,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      // Open with the caret in the field so a desktop user can simply type and
      // an Android user gets the IME without a further press. A numeric
      // prompt opens on the stepper instead: the D-pad is the quicker way in.
      if (widget.stepper == null) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_navLayerId);
    _gamepadNav.dispose();
    _nameFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Moves between the three stops. Deliberately inert while the field holds
  /// focus: the D-pad must not be a way out of a text field.
  void _move(int delta) {
    if (_nameFocus.hasFocus) return;
    final next = (_stop.index + delta).clamp(
      0,
      _NameDialogStop.values.length - 1,
    );
    if (next == _stop.index) return;
    SfxService().playNavSound();
    setState(() => _stop = _NameDialogStop.values[next]);
  }

  /// Left/right step a numeric value while its field is selected but not
  /// being typed in; otherwise they move between stops like up/down.
  void _horizontal(int delta) {
    if (widget.stepper != null &&
        _stop == _NameDialogStop.field &&
        !_nameFocus.hasFocus) {
      _step(delta);
      return;
    }
    _move(delta);
  }

  void _step(int direction) {
    final stepper = widget.stepper!;
    final current = num.tryParse(_controller.text.trim().replaceAll(',', '.'));
    var next = current == null
        ? stepper.start
        : current + stepper.step * direction;
    if (next < stepper.min) next = stepper.min;
    if (stepper.max != null && next > stepper.max!) next = stepper.max!;
    final text = next == next.roundToDouble() ? '${next.round()}' : '$next';
    if (text == _controller.text) return;
    SfxService().playNavSound();
    setState(() {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  void _activate() {
    if (_nameFocus.hasFocus) {
      // A while typing means "done": drop the keyboard and land on Confirm so
      // the next press commits.
      _nameFocus.unfocus();
      setState(() => _stop = _NameDialogStop.confirm);
      return;
    }
    switch (_stop) {
      case _NameDialogStop.field:
        _nameFocus.requestFocus();
      case _NameDialogStop.cancel:
        _cancel();
      case _NameDialogStop.confirm:
        _confirm();
    }
  }

  void _handleBack() {
    if (_nameFocus.hasFocus) {
      _nameFocus.unfocus();
      return;
    }
    _cancel();
  }

  void _cancel() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _confirm() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      // Nothing to save — send the user back to the field instead of closing.
      setState(() => _stop = _NameDialogStop.field);
      _nameFocus.requestFocus();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(name);
  }

  /// Flanks a numeric field with tappable chevrons, which also tell a
  /// controller user that left/right adjust the value.
  Widget _withStepper(ThemeData theme, Widget field) {
    if (widget.stepper == null) return field;
    Widget chevron(IconData icon, int direction) => InkWell(
      onTap: () {
        setState(() => _stop = _NameDialogStop.field);
        _step(direction);
      },
      child: Padding(
        padding: EdgeInsets.all(6.r),
        child: Icon(icon, size: 20.r, color: theme.colorScheme.primary),
      ),
    );
    return Row(
      children: [
        chevron(Symbols.chevron_left_rounded, -1),
        Expanded(child: field),
        chevron(Symbols.chevron_right_rounded, 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>();
    final fieldFocused = _stop == _NameDialogStop.field;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      title: Row(
        children: [
          Icon(
            Symbols.bookmark_rounded,
            color: theme.colorScheme.primary,
            size: 20.r,
          ),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              widget.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 14.r,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 320.r,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radii?.radiusInternal ?? BorderRadius.circular(12.r),
            border: Border.all(
              color: fieldFocused
                  ? theme.colorScheme.primary
                  : Colors.transparent,
              width: 2.r,
            ),
          ),
          child: _withStepper(
            theme,
            TextField(
              controller: _controller,
              focusNode: _nameFocus,
              keyboardType: widget.stepper == null
                  ? null
                  : TextInputType.numberWithOptions(
                      decimal: widget.stepper!.decimal,
                    ),
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onTap: () => setState(() => _stop = _NameDialogStop.field),
              onSubmitted: (_) => _nameFocus.unfocus(),
              style: TextStyle(
                fontSize: 13.r,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText:
                    widget.hintText ??
                    AppLocale.collectionName.getString(context),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12.r,
                  vertical: 10.r,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                border: OutlineInputBorder(
                  borderRadius:
                      radii?.radiusInternal ?? BorderRadius.circular(12.r),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        _buildAction(
          theme,
          label: AppLocale.cancel.getString(context),
          iconAsset: 'assets/images/gamepad/Xbox_B_button.png',
          selected: _stop == _NameDialogStop.cancel,
          background: theme.colorScheme.onSurface.withValues(alpha: 0.1),
          foreground: theme.colorScheme.onSurface.withValues(alpha: 0.8),
          onTap: _cancel,
        ),
        SizedBox(width: 8.r),
        _buildAction(
          theme,
          label: widget.confirmLabel,
          iconAsset: 'assets/images/gamepad/Xbox_A_button.png',
          selected: _stop == _NameDialogStop.confirm,
          background: theme.colorScheme.primary,
          foreground: theme.colorScheme.onPrimary,
          onTap: _confirm,
        ),
      ],
    );
  }

  /// One dialog button, ringed when it is the focused stop so the selection is
  /// visible without a mouse.
  Widget _buildAction(
    ThemeData theme, {
    required String label,
    required String iconAsset,
    required bool selected,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9.r),
        border: Border.all(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          width: 2.r,
        ),
      ),
      padding: EdgeInsets.all(2.r),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: Image.asset(
                    iconAsset,
                    color: foreground,
                    colorBlendMode: BlendMode.srcIn,
                  ),
                ),
                SizedBox(width: 4.r),
                Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.r,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
