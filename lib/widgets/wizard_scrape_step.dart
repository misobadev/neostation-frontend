import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/screenscraper_options.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/screenscraper_service.dart';

/// The choices the setup wizard's scraping step edits before it starts the
/// first scrape: one preferred region, the metadata language, and which media
/// to download.
///
/// Rows, top to bottom: region, language, then one per media type. Up/down
/// moves between them and left/right changes the focused one, so A is free to
/// start the scrape. The full region priority list stays in Settings; here the
/// preferred region just moves to its front.
class ScrapeSetupChoices extends ChangeNotifier {
  static const int regionRow = 0;
  static const int languageRow = 1;
  static const int mediaStart = 2;

  static final List<String> _regions = ScreenScraperOptions.regionNames.keys
      .toList();
  static final List<String> _languages = ScreenScraperOptions.languages.keys
      .toList();

  int _row = regionRow;
  String _region = _regions.first;
  String _language = _languages.first;
  Set<String> _media = {...ScreenScraperOptions.mediaTypes};
  List<String> _regionPriority = [..._regions];

  int get row => _row;
  String get region => _region;
  String get language => _language;
  Set<String> get media => Set.unmodifiable(_media);
  int get rowCount => mediaStart + ScreenScraperOptions.mediaTypes.length;

  /// Seeds the choices from what is saved: the top region of the saved
  /// priority, the account's language, and the enabled media types.
  Future<void> load() async {
    final results = await Future.wait<Object?>([
      ScraperRepository.getRegionPriority(),
      ScreenScraperService.getSavedCredentials(),
      ScraperRepository.getEnabledMediaTypes(),
    ]);
    final priority = results[0] as List<String>;
    final credentials = results[1] as Map<String, String>?;
    final media = results[2] as List<String>;
    seed(
      regionPriority: priority,
      language: credentials?['preferred_language'],
      media: media,
    );
  }

  /// Sets the choices directly. [load] goes through here; tests call it too.
  @visibleForTesting
  void seed({
    required List<String> regionPriority,
    String? language,
    required List<String> media,
  }) {
    if (regionPriority.isNotEmpty) _regionPriority = [...regionPriority];
    final top = _regionPriority.isEmpty ? null : _regionPriority.first;
    if (top != null && _regions.contains(top)) _region = top;
    if (language != null && _languages.contains(language)) {
      _language = language;
    }
    _media = media.toSet();
    notifyListeners();
  }

  void moveRow(int delta) {
    final next = (_row + delta).clamp(0, rowCount - 1);
    if (next == _row) return;
    _row = next;
    notifyListeners();
  }

  /// Focuses [row] (a touch on it). Returns whether it was already focused,
  /// so a tap on the focused row can change it like a D-pad press would.
  bool focusRow(int row) {
    if (row == _row) return true;
    _row = row.clamp(0, rowCount - 1);
    notifyListeners();
    return false;
  }

  /// Changes the focused row: cycles region or language by [delta], or flips
  /// a media type whichever way [delta] points.
  void change(int delta) {
    switch (_row) {
      case regionRow:
        _region = _cycle(_regions, _region, delta);
      case languageRow:
        _language = _cycle(_languages, _language, delta);
      default:
        final type = ScreenScraperOptions.mediaTypes[_row - mediaStart];
        if (!_media.remove(type)) _media.add(type);
    }
    notifyListeners();
  }

  static String _cycle(List<String> values, String current, int delta) {
    final i = values.indexOf(current);
    return values[(i + delta) % values.length];
  }

  /// The saved priority with [preferred] moved to the front and the rest left
  /// in their order.
  static List<String> priorityWith(String preferred, List<String> priority) => [
    preferred,
    ...priority.where((r) => r != preferred),
  ];

  /// The region priority [apply] saves.
  List<String> get regionPriority => priorityWith(_region, _regionPriority);

  /// Saves the choices. Returns false if any of them failed to save.
  Future<bool> apply() async {
    final saved = await Future.wait([
      ScraperRepository.saveRegionPriority(regionPriority),
      ScraperRepository.saveEnabledMediaTypes(
        // In display order, as Settings writes them.
        [
          for (final t in ScreenScraperOptions.mediaTypes)
            if (_media.contains(t)) t,
        ],
      ),
      _saveLanguage(),
    ]);
    return saved.every((ok) => ok);
  }

  /// The language is stored on the account row, so it is saved the way the
  /// Settings language row saves it: rewriting the credentials with it.
  Future<bool> _saveLanguage() async {
    final info = await ScreenScraperService.getSavedCredentials();
    if (info == null) return false;
    if (info['preferred_language'] == _language) return true;
    return ScreenScraperService.saveCredentials(
      info['username']!,
      info['password']!,
      info,
      _language,
    );
  }
}

/// The scraping step: region, language and media rows over the choices in
/// [choices], with a hint that A starts the scrape.
///
/// The rows don't all fit a handheld's card, so the focused one is scrolled
/// into view whenever the D-pad moves it.
class WizardScrapeStep extends StatefulWidget {
  const WizardScrapeStep({super.key, required this.choices});

  final ScrapeSetupChoices choices;

  /// A media type's name, as Settings → ScreenScraper shows it.
  static String mediaTitle(BuildContext context, String type) => switch (type) {
    'fanart' => AppLocale.scrapeFanart.getString(context),
    'ss' => AppLocale.scrapeScreenshot.getString(context),
    'wheel' => AppLocale.scrapeWheel.getString(context),
    'box2D' => AppLocale.scrapeBox2D.getString(context),
    'video' => AppLocale.scrapeVideo.getString(context),
    _ => type,
  };

  @override
  State<WizardScrapeStep> createState() => _WizardScrapeStepState();
}

class _WizardScrapeStepState extends State<WizardScrapeStep> {
  late final List<GlobalKey> _rowKeys = List.generate(
    widget.choices.rowCount,
    (_) => GlobalKey(),
  );
  late int _lastRow = widget.choices.row;

  ScrapeSetupChoices get choices => widget.choices;

  @override
  void initState() {
    super.initState();
    choices.addListener(_onChoicesChanged);
  }

  @override
  void dispose() {
    choices.removeListener(_onChoicesChanged);
    super.dispose();
  }

  void _onChoicesChanged() {
    if (choices.row == _lastRow) return;
    _lastRow = choices.row;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[choices.row].currentContext;
      if (rowContext == null) return;
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;

    return ListenableBuilder(
      listenable: choices,
      builder: (context, _) {
        Widget row(int index, String label, Widget value) => _ChoiceRow(
          key: _rowKeys[index],
          label: label,
          value: value,
          focused: choices.row == index,
          textSize: textSize,
          onTap: () {
            if (choices.focusRow(index)) choices.change(1);
          },
        );

        return SingleChildScrollView(
          child: Column(
            children: [
              Text(
                AppLocale.wizardScrapeStepTitle.getString(context),
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: isLandscape ? 6.r : 12.r),
              Text(
                AppLocale.wizardScrapeStepDesc.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: isLandscape ? 10.r : 20.r),
              row(
                ScrapeSetupChoices.regionRow,
                AppLocale.wizardPreferredRegion.getString(context),
                _Cycler(
                  text:
                      ScreenScraperOptions.regionNames[choices.region] ??
                      choices.region,
                  textSize: textSize,
                ),
              ),
              row(
                ScrapeSetupChoices.languageRow,
                AppLocale.preferredLanguage.getString(context),
                _Cycler(
                  text:
                      ScreenScraperOptions.languages[choices.language] ??
                      choices.language,
                  textSize: textSize,
                ),
              ),
              for (var i = 0; i < ScreenScraperOptions.mediaTypes.length; i++)
                row(
                  ScrapeSetupChoices.mediaStart + i,
                  WizardScrapeStep.mediaTitle(
                    context,
                    ScreenScraperOptions.mediaTypes[i],
                  ),
                  Icon(
                    choices.media.contains(ScreenScraperOptions.mediaTypes[i])
                        ? Symbols.check_box_rounded
                        : Symbols.check_box_outline_blank_rounded,
                    fill: 1,
                    size: textSize + 8.r,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.focused,
    required this.textSize,
    required this.onTap,
  });

  final String label;
  final Widget value;
  final bool focused;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 4.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 1.5.r,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: textSize,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            value,
          ],
        ),
      ),
    );
  }
}

/// A value with arrows either side, for the rows left/right cycles through.
class _Cycler extends StatelessWidget {
  const _Cycler({required this.text, required this.textSize});

  final String text;
  final double textSize;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.chevron_left_rounded, size: textSize + 6.r, color: color),
        Text(
          text,
          style: TextStyle(fontSize: textSize, color: color),
        ),
        Icon(Symbols.chevron_right_rounded, size: textSize + 6.r, color: color),
      ],
    );
  }
}
