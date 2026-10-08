import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/collection_model.dart';
import '../../models/database_game_model.dart';
import '../../models/game_model.dart';
import '../../models/smart_collection_rules.dart';
import '../../providers/collections_provider.dart';
import '../../providers/file_provider.dart';
import '../../services/collections/smart_collection_evaluator.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/context_menu/anchored_context_menu.dart';
import 'collection_name_dialog.dart';

class SmartCollectionDraft {
  final String name;
  final SmartCollectionRules rules;
  const SmartCollectionDraft(this.name, this.rules);
}

/// Full-screen editor; nested pickers own their own gamepad layers.
class SmartCollectionEditor extends StatefulWidget {
  final CollectionModel? collection;
  final String initialName;
  const SmartCollectionEditor({
    super.key,
    this.collection,
    required this.initialName,
  });

  static Future<SmartCollectionDraft?> show(
    BuildContext context, {
    CollectionModel? collection,
    required String initialName,
  }) => Navigator.of(context).push<SmartCollectionDraft>(
    MaterialPageRoute(
      builder: (_) => SmartCollectionEditor(
        collection: collection,
        initialName: initialName,
      ),
    ),
  );

  @override
  State<SmartCollectionEditor> createState() => _SmartCollectionEditorState();
}

class _RuleDraft {
  SmartField field;
  SmartOperator operator;
  Object? value;
  num? upper;
  _RuleDraft({
    this.field = SmartField.system,
    this.operator = SmartOperator.isEqual,
    this.value,
    this.upper,
  });

  SmartRule? get rule {
    if (value == null) return null;
    try {
      return SmartRule(
        field: field,
        operator: operator,
        value: value!,
        upper: upper,
      );
    } catch (_) {
      return null;
    }
  }
}

class _SmartCollectionEditorState extends State<SmartCollectionEditor> {
  static int _sequence = 0;
  late final String _layer = 'smart_collection_editor#${++_sequence}';
  late final GamepadNavigation _nav;
  late String _name;
  late bool _matchAll;
  late final List<_RuleDraft> _rules;
  List<DatabaseGameModel> _library = [];
  bool _loading = true;
  bool _loadError = false;
  bool _busy = false;
  String? _error;
  int _selected = 0;
  bool _previewFocused = false;
  int _previewSelected = 0;
  List<DatabaseGameModel> _previewGames = [];
  final _scrollController = ScrollController();
  final _rulesSectionKey = GlobalKey();
  final Map<String, GlobalKey> _keys = {};
  final List<VoidCallback> _actions = [];
  final List<GlobalKey> _actionKeys = [];
  final List<String> _actionRows = [];

  String _text(String key) => key.getString(context);

  @override
  void initState() {
    super.initState();
    _name = widget.initialName;
    _matchAll = widget.collection?.rules?.matchAll ?? true;
    _rules =
        widget.collection?.rules?.rules
            .map(
              (r) => _RuleDraft(
                field: r.field,
                operator: r.operator,
                value: r.value,
                upper: r.upper,
              ),
            )
            .toList() ??
        [_RuleDraft()];
    _nav = GamepadNavigation(
      allowRepeat: true,
      onNavigateUp: () => _move(-1, vertical: true),
      onNavigateDown: () => _move(1, vertical: true),
      onNavigateLeft: () => _move(-1),
      onNavigateRight: () => _move(1),
      onSelectItem: () {
        if (!_busy && !_previewFocused && _selected < _actions.length) {
          _actions[_selected]();
        }
      },
      onBack: _cancel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nav.initialize();
      GamepadNavigationManager.pushLayer(
        _layer,
        onActivate: _nav.activate,
        onDeactivate: _nav.deactivate,
      );
      _loadLibrary();
    });
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final games = await context.read<CollectionsProvider>().ruleLibrary();
      if (mounted) {
        setState(() {
          _library = games;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError = true;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layer);
    _nav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _move(int delta, {bool vertical = false}) {
    if (_busy || _actions.isEmpty) return;
    if (_previewFocused) {
      if (!vertical ||
          (delta > 0 && _previewSelected == _previewGames.length - 1)) {
        setState(() {
          _previewFocused = false;
          _selected =
              _actionRows.indexOf('footer') + (!vertical && delta > 0 ? 1 : 0);
        });
      } else if (delta < 0 && _previewSelected == 0) {
        setState(() {
          _previewFocused = false;
          _selected = _actionRows.indexOf('add');
        });
        _revealAction();
      } else {
        setState(() => _previewSelected += delta);
        _revealPreview();
      }
      return;
    }
    final row = _actionRows[_selected];
    if (vertical &&
        _previewGames.isNotEmpty &&
        ((row == 'add' && delta > 0) || (row == 'footer' && delta < 0))) {
      setState(() {
        _previewFocused = true;
        if (row == 'add') _previewSelected = 0;
      });
      _revealPreview();
      return;
    }
    final columns = [
      for (var i = 0; i < _actionRows.length; i++)
        if (_actionRows[i] == row) i,
    ];
    final column = columns.indexOf(_selected);
    int next;
    if (vertical) {
      final rows = _actionRows.toSet().toList();
      final nextRow =
          rows[(rows.indexOf(row) + delta).clamp(0, rows.length - 1)];
      final targets = [
        for (var i = 0; i < _actionRows.length; i++)
          if (_actionRows[i] == nextRow) i,
      ];
      next = targets[column.clamp(0, targets.length - 1)];
    } else {
      next = columns[(column + delta).clamp(0, columns.length - 1)];
    }
    setState(() => _selected = next);
    _revealAction();
  }

  void _revealPreview() {
    final section = _rulesSectionKey.currentContext?.findRenderObject();
    if (section is! RenderBox || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final offset =
        section.size.height +
        (_previewSelected + .5) * 76.r -
        position.viewportDimension / 2;
    _scrollController.animateTo(
      offset.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  void _revealAction() {
    final target = _actionKeys[_selected].currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 120),
        alignment: .5,
      );
    }
  }

  void _cancel() {
    if (!_busy && mounted) Navigator.of(context).pop();
  }

  SmartCollectionRules? get _definition {
    final rules = _rules.map((r) => r.rule).toList();
    if (rules.isEmpty || rules.contains(null)) return null;
    return SmartCollectionRules(
      matchAll: _matchAll,
      rules: rules.cast<SmartRule>(),
    );
  }

  void _save() {
    final definition = _definition;
    if (_name.trim().isEmpty || definition == null) {
      setState(() => _error = _text(AppLocale.smartInvalidValue));
      return;
    }
    Navigator.of(context).pop(SmartCollectionDraft(_name.trim(), definition));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<String?> _prompt(String title, String initial) =>
      CollectionNameDialog.show(
        context,
        title: title,
        initialValue: initial,
        confirmLabel: _text(AppLocale.save),
      );

  Future<String?> _pick(String title, Map<String, String> options) async {
    if (!mounted) return null;
    return showAnchoredContextMenu(
      context: context,
      items: [
        for (final entry in options.entries)
          ContextMenuItem(
            id: entry.key,
            label: entry.value,
            icon: Symbols.chevron_right_rounded,
          ),
      ],
      layerId: '${_layer}_picker',
      submenuLayerId: '${_layer}_submenu',
      alignment: ContextMenuAlignment.overAnchor,
    );
  }

  String _fieldLabel(SmartField field) => _text(switch (field) {
    SmartField.system => AppLocale.smartSystem,
    SmartField.title => AppLocale.smartTitle,
    SmartField.genre => AppLocale.genre,
    SmartField.developer => AppLocale.developer,
    SmartField.publisher => AppLocale.publisher,
    SmartField.year => AppLocale.smartYear,
    SmartField.rating => AppLocale.smartRating,
    SmartField.favorite => AppLocale.favorite,
    SmartField.played => AppLocale.smartPlayed,
    SmartField.playTime => AppLocale.playTime,
    SmartField.lastPlayed => AppLocale.lastPlayed,
  });

  String _operatorLabel(SmartOperator op) => _text(switch (op) {
    SmartOperator.isEqual => AppLocale.smartIs,
    SmartOperator.isNot => AppLocale.smartIsNot,
    SmartOperator.contains => AppLocale.smartContains,
    SmartOperator.notContains => AppLocale.smartNotContains,
    SmartOperator.before => AppLocale.smartBefore,
    SmartOperator.after => AppLocale.smartAfter,
    SmartOperator.atLeast => AppLocale.smartAtLeast,
    SmartOperator.atMost => AppLocale.smartAtMost,
    SmartOperator.between => AppLocale.smartBetween,
    SmartOperator.withinDays => AppLocale.smartWithinDays,
    SmartOperator.notWithinDays => AppLocale.smartNotWithinDays,
  });

  Future<void> _editField(_RuleDraft row) async {
    final choice = await _pick(_text(AppLocale.smartAddRule), {
      for (final field in SmartField.values) field.name: _fieldLabel(field),
    });
    if (choice == null || !mounted) return;
    final field = SmartField.values.byName(choice);
    if (field == row.field) return;
    setState(() {
      row.field = field;
      row.operator = operatorsFor(field).first;
      row.value = field == SmartField.favorite || field == SmartField.played
          ? true
          : null;
      row.upper = null;
      _error = null;
    });
  }

  Future<void> _editOperator(_RuleDraft row) async {
    final choice = await _pick(_fieldLabel(row.field), {
      for (final op in operatorsFor(row.field)) op.name: _operatorLabel(op),
    });
    if (choice == null || !mounted) return;
    setState(() {
      row.operator = SmartOperator.values.byName(choice);
      row.upper = null;
      _error = null;
    });
  }

  Map<String, String> get _systems => {
    for (final game in _library)
      if (game.systemFolderName != null)
        game.systemFolderName!: game.systemRealName ?? game.systemFolderName!,
  };

  Future<void> _editValue(_RuleDraft row) async {
    Object? value;
    num? upper;
    if (row.field == SmartField.system) {
      final selected = Set<String>.from(row.value as List<String>? ?? []);
      final systems = {
        ..._systems,
        for (final id in selected) id: _systems[id] ?? id,
      };
      final entries = systems.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      await showAnchoredContextMenu(
        context: context,
        items: [
          for (final e in entries)
            ContextMenuItem(
              id: e.key,
              label: e.value,
              checkable: true,
              selected: selected.contains(e.key),
            ),
          ContextMenuItem(
            id: '__done__',
            label: _text(AppLocale.smartDone),
            icon: Symbols.check_rounded,
          ),
        ],
        layerId: '${_layer}_systems',
        submenuLayerId: '${_layer}_systems_submenu',
        onToggle: (id, {required checked}) async {
          if (checked) {
            selected.add(id);
          } else {
            selected.remove(id);
          }
          return true;
        },
      );
      value = selected.toList();
    } else if (row.field == SmartField.favorite ||
        row.field == SmartField.played) {
      final choice = await _pick(_fieldLabel(row.field), {
        'yes': _text(AppLocale.smartYes),
        'no': _text(AppLocale.smartNo),
      });
      if (choice == null) return;
      value = choice == 'yes';
    } else if ([
      SmartField.title,
      SmartField.genre,
      SmartField.developer,
      SmartField.publisher,
    ].contains(row.field)) {
      final values =
          _library
              .map(
                (g) => switch (row.field) {
                  SmartField.genre => g.genre,
                  SmartField.developer => g.developer,
                  SmartField.publisher => g.publisher,
                  _ => null,
                },
              )
              .whereType<String>()
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (row.value is String && !values.contains(row.value)) {
        values.insert(0, row.value as String);
      }
      if (row.field != SmartField.title && values.isNotEmpty) {
        final choice = await _pick(_fieldLabel(row.field), {
          for (var i = 0; i < values.length; i++) '$i': values[i],
          'custom': _text(AppLocale.smartCustomValue),
        });
        if (choice == null || !mounted) return;
        value = choice == 'custom'
            ? await _prompt(_fieldLabel(row.field), row.value?.toString() ?? '')
            : values[int.parse(choice)];
      } else {
        value = await _prompt(
          _fieldLabel(row.field),
          row.value?.toString() ?? '',
        );
      }
    } else {
      final suffix = row.field == SmartField.playTime
          ? ' (${_text(AppLocale.minutes)})'
          : '';
      final input = await _prompt(
        '${_fieldLabel(row.field)}$suffix',
        row.value?.toString() ?? '',
      );
      if (input == null || !mounted) return;
      value = num.tryParse(input.replaceAll(',', '.'));
      if (row.operator == SmartOperator.between) {
        final second = await _prompt(
          _text(AppLocale.smartUpper),
          row.upper?.toString() ?? '',
        );
        if (second == null || !mounted) return;
        upper = num.tryParse(second.replaceAll(',', '.'));
      }
    }
    if (value == null &&
        [
          SmartField.title,
          SmartField.genre,
          SmartField.developer,
          SmartField.publisher,
        ].contains(row.field)) {
      return;
    }
    if (!mounted || value == null) {
      if (mounted && value == null) {
        setState(() => _error = _text(AppLocale.smartInvalidValue));
      }
      return;
    }
    final candidate = _RuleDraft(
      field: row.field,
      operator: row.operator,
      value: value,
      upper: upper,
    );
    if (candidate.rule == null) {
      setState(() => _error = _text(AppLocale.smartInvalidValue));
      return;
    }
    setState(() {
      row.value = value;
      row.upper = upper;
      _error = null;
    });
  }

  String _valueLabel(_RuleDraft row) {
    if (row.value == null) return _text(AppLocale.smartChooseValue);
    if (row.value is bool) {
      return _text(row.value == true ? AppLocale.smartYes : AppLocale.smartNo);
    }
    if (row.value is List<String>) {
      return (row.value as List<String>)
          .map((id) => _systems[id] ?? id)
          .join(', ');
    }
    if (row.field == SmartField.lastPlayed) {
      return _text(AppLocale.smartDays).replaceFirst('{count}', '${row.value}');
    }
    final text = row.upper == null
        ? '${row.value}'
        : '${row.value} – ${row.upper}';
    return row.field == SmartField.playTime
        ? '$text ${_text(AppLocale.minutes)}'
        : text;
  }

  Widget _button(
    String id,
    String label,
    VoidCallback action, {
    IconData? icon,
    String? navigationRow,
  }) {
    final index = _actions.length;
    final key = _keys.putIfAbsent(id, () => GlobalKey());
    _actions.add(action);
    _actionKeys.add(key);
    _actionRows.add(navigationRow ?? id);
    final selected = !_previewFocused && _selected == index;
    final theme = Theme.of(context);
    return ExcludeFocus(
      child: Padding(
        key: key,
        padding: EdgeInsets.all(3.r),
        child: OutlinedButton(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _previewFocused = false;
                    _selected = index;
                  });
                  action();
                },
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
            side: BorderSide(
              color: selected ? theme.colorScheme.primary : theme.dividerColor,
              width: selected ? 2.r : 1.r,
            ),
            backgroundColor: selected
                ? theme.colorScheme.primary.withValues(alpha: .12)
                : null,
            foregroundColor: theme.colorScheme.onSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18.r),
                SizedBox(width: 6.r),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.r),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewGame(DatabaseGameModel databaseGame, int index) {
    final game = GameModel.fromDatabaseModel(databaseGame);
    final folder = databaseGame.systemFolderName ?? '';
    final fileProvider = context.read<FileProvider>();
    final artPath = game.getImagePath(folder, 'box2d', fileProvider);
    final theme = Theme.of(context);
    Widget placeholder() => ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Symbols.videogame_asset_rounded,
          size: 24.r,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final selected = _previewFocused && _previewSelected == index;
    return Container(
      key: ValueKey('preview:${databaseGame.romPath}'),
      padding: EdgeInsets.symmetric(vertical: 6.r, horizontal: 3.r),
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: .12)
            : null,
        borderRadius: BorderRadius.circular(9.r),
        border: selected
            ? Border.all(color: theme.colorScheme.primary, width: 2.r)
            : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56.r,
            height: 64.r,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4.r),
              child: File(artPath).existsSync()
                  ? Image.file(
                      File(artPath),
                      fit: BoxFit.contain,
                      cacheWidth:
                          (112.r * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                      errorBuilder: (context, error, stackTrace) =>
                          placeholder(),
                    )
                  : placeholder(),
            ),
          ),
          SizedBox(width: 12.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (databaseGame.screenscraperRealName?.trim().isNotEmpty ??
                          false)
                      ? databaseGame.screenscraperRealName!
                      : (databaseGame.realName?.trim().isNotEmpty ?? false)
                      ? databaseGame.realName!
                      : databaseGame.filename,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.r),
                ),
                if (databaseGame.systemRealName != null) ...[
                  SizedBox(height: 4.r),
                  Text(
                    databaseGame.systemRealName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11.r,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _actions.clear();
    _actionKeys.clear();
    _actionRows.clear();
    final theme = Theme.of(context);
    final definition = _definition;
    final evaluator = SmartCollectionEvaluator(DateTime.now());
    final matches = definition == null
        ? <DatabaseGameModel>[]
        : _library.where((g) => evaluator.matches(g, definition)).toList();
    _previewGames = !_loading && !_loadError ? matches : [];
    if (_previewGames.isEmpty) {
      _previewFocused = false;
      _previewSelected = 0;
    } else {
      _previewSelected = _previewSelected.clamp(0, _previewGames.length - 1);
    }
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(18.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Symbols.auto_awesome_rounded,
                      size: 24.r,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(width: 10.r),
                    Text(
                      _text(AppLocale.smartCollection),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 20.r,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12.r),
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          key: _rulesSectionKey,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _button(
                              'name',
                              '${_text(AppLocale.collectionName)}: $_name',
                              () => _run(() async {
                                final name = await _prompt(
                                  _text(AppLocale.collectionName),
                                  _name,
                                );
                                if (name != null && mounted) {
                                  setState(() => _name = name);
                                }
                              }),
                              icon: Symbols.edit_rounded,
                            ),
                            _button(
                              'mode',
                              _text(
                                _matchAll
                                    ? AppLocale.smartMatchAll
                                    : AppLocale.smartMatchAny,
                              ),
                              () => setState(() => _matchAll = !_matchAll),
                            ),
                            if (widget.collection?.rulesInvalid ?? false)
                              Padding(
                                padding: EdgeInsets.all(8.r),
                                child: Text(
                                  _text(AppLocale.smartInvalidRules),
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                    fontSize: 12.r,
                                  ),
                                ),
                              ),
                            SizedBox(height: 12.r),
                            for (var i = 0; i < _rules.length; i++)
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: _button(
                                      'field:$i',
                                      _fieldLabel(_rules[i].field),
                                      () => _run(() => _editField(_rules[i])),
                                      navigationRow: 'rule:$i',
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: _button(
                                      'op:$i',
                                      _operatorLabel(_rules[i].operator),
                                      () =>
                                          _run(() => _editOperator(_rules[i])),
                                      navigationRow: 'rule:$i',
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: _button(
                                      'value:$i',
                                      _valueLabel(_rules[i]),
                                      () => _run(() => _editValue(_rules[i])),
                                      navigationRow: 'rule:$i',
                                    ),
                                  ),
                                  _button(
                                    'remove:$i',
                                    _text(AppLocale.delete),
                                    () => setState(() {
                                      _rules.removeAt(i);
                                      _selected = 0;
                                      _error = null;
                                    }),
                                    icon: Symbols.delete_rounded,
                                    navigationRow: 'rule:$i',
                                  ),
                                ],
                              ),
                            _button(
                              'add',
                              _text(AppLocale.smartAddRule),
                              () => setState(() => _rules.add(_RuleDraft())),
                              icon: Symbols.add_rounded,
                            ),
                            if (_error != null)
                              Padding(
                                padding: EdgeInsets.all(8.r),
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                    fontSize: 12.r,
                                  ),
                                ),
                              ),
                            SizedBox(height: 20.r),
                            Text(
                              _text(AppLocale.smartRulesOnly),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 13.r,
                              ),
                            ),
                            SizedBox(height: 12.r),
                            if (_loading)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: EdgeInsets.all(8.r),
                                  child: const CircularProgressIndicator(),
                                ),
                              )
                            else if (_loadError) ...[
                              Text(
                                _text(AppLocale.smartPreviewError),
                                style: TextStyle(fontSize: 12.r),
                              ),
                              _button(
                                'retry',
                                _text(AppLocale.retry),
                                _loadLibrary,
                              ),
                            ] else ...[
                              Text(
                                _text(
                                  matches.length == 1
                                      ? AppLocale.smartMatchesOne
                                      : AppLocale.smartMatches,
                                ).replaceFirst('{count}', '${matches.length}'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontSize: 14.r,
                                ),
                              ),
                              SizedBox(height: 8.r),
                              if (matches.isEmpty)
                                Text(
                                  _text(AppLocale.smartNoMatches),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 12.r,
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      if (!_loading && !_loadError)
                        SliverFixedExtentList.builder(
                          itemExtent: 76.r,
                          itemCount: matches.length,
                          itemBuilder: (context, index) =>
                              _previewGame(matches[index], index),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 8.r),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _button(
                      'cancel',
                      _text(AppLocale.cancel),
                      _cancel,
                      navigationRow: 'footer',
                    ),
                    _button(
                      'save',
                      _text(AppLocale.save),
                      _save,
                      icon: Symbols.check_rounded,
                      navigationRow: 'footer',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
