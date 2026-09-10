import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../providers/file_provider.dart';
import '../../../../services/screenscraper_service.dart';
import '../../../../themes/chrome_surface.dart';
import '../../../../themes/corner_radii.dart';
import '../../../../utils/game_utils.dart';
import '../widgets/panel_gate_highlight.dart';
import '../widgets/scrolling_status_line.dart';

class GameDetailsGameInfoTab extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;
  final String description;

  /// Hides the metadata pills while the card's scrape panel covers this tab.
  final bool isScrapingGame;
  final VoidCallback onScrapeGame;

  /// How far above the card's bottom edge the panel stops, in the same
  /// unscaled units as the other offsets. The card works it out from what the
  /// footer under it will draw, so the panel takes back the room a missing
  /// achievements pill leaves behind.
  final double bottomOffset;

  const GameDetailsGameInfoTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    required this.description,
    required this.isScrapingGame,
    required this.onScrapeGame,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsGameInfoTab> createState() => GameDetailsGameInfoTabState();
}

class GameDetailsGameInfoTabState extends State<GameDetailsGameInfoTab> {
  /// App language code -> the key the scraper files that language under.
  ///
  /// Only the two that actually differ are listed. ScreenScraper writes
  /// Japanese as `jp` where the app calls it `ja`, and it has one Chinese
  /// bucket where the app offers simplified and traditional separately, so
  /// both app variants read the same text. Every other app language is its own
  /// key, and `id` has no bucket at all — it falls through to English like any
  /// other language a game was not scraped in.
  static const Map<String, String> _descriptionKeys = {
    'ja': 'jp',
    'zh': 'zh',
    'zh_Hant': 'zh',
  };

  /// Drives the description pane: the D-pad scrolls it while the panel is
  /// active, and a finger can drag it at any time.
  final ScrollController _descriptionController = ScrollController();

  /// Whether the panel owns the D-pad.
  ///
  /// Same gate as the achievements panel: arriving on this tab must not
  /// swallow the D-pad, so left/right keep walking the tabs and up/down keep
  /// moving the games list until A steps in. B steps back out.
  bool _isPanelActive = false;

  /// How far one D-pad press moves the description: about three lines, so a
  /// press is a readable step rather than a jump.
  double get _scrollStep => 56.r;

  /// Whether the panel currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  /// Whether the panel's edge is currently lit as enterable.
  ///
  /// It cannot be answered during a build: [_canScroll] reads a scroll metric
  /// that does not exist until the description has been laid out, so the
  /// panel's own first frame always says "nothing to drive". Held in state and
  /// refreshed once the frame is up, rather than read live in [build].
  bool _isDrivable = false;

  /// Re-reads whether there is anything in here to drive, one frame late.
  ///
  /// Without this the panel kept its first-frame answer until something else
  /// rebuilt the card — and the next thing that does is the tab slide
  /// finishing, so the highlight arrived exactly as the panel came to rest.
  void _refreshDrivability() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final drivable = _canScroll;
      if (drivable != _isDrivable) setState(() => _isDrivable = drivable);
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshDrivability();
  }

  /// Whether the description is longer than its pane.
  bool get _canScroll =>
      _descriptionController.hasClients &&
      _descriptionController.position.maxScrollExtent > 0;

  /// Hands the D-pad to the panel. Returns whether the input was consumed.
  ///
  /// Refuses when there is nothing to drive: a description that fits in its
  /// pane leaves the D-pad better spent on the tabs and the list. Scrolling is
  /// now the only thing in here to drive — the language strip that was the
  /// other half of this gate is gone.
  bool enterPanel() {
    if (_isPanelActive) return true; // Already inside — A stays consumed.
    if (!_canScroll) return false;

    setState(() => _isPanelActive = true);
    return true;
  }

  /// Gives the D-pad back to the details card. Returns whether it was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;

    setState(() => _isPanelActive = false);
    return true;
  }

  /// Gamepad navigation delegate: scrolls the description up one step.
  void moveUp() => _scrollDescription(-_scrollStep);

  /// Gamepad navigation delegate: scrolls the description down one step.
  void moveDown() => _scrollDescription(_scrollStep);

  /// Gamepad navigation delegate: nothing to the left or right in here.
  ///
  /// These used to walk the language strip. The panel shows one language now —
  /// the user's — so there is no horizontal axis left to drive. They stay as
  /// no-ops rather than being unregistered: the card dispatches left/right to
  /// whichever panel holds the D-pad, and a panel that is being read should
  /// swallow them rather than let a stray press slide the tab out from under
  /// the text. B is the way out, as everywhere else.
  void moveLeft() {}

  /// Gamepad navigation delegate: see [moveLeft].
  void moveRight() {}

  void _scrollDescription(double delta) {
    if (!_isPanelActive || !_descriptionController.hasClients) return;

    final position = _descriptionController.position;
    final target = (position.pixels + delta).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return;

    _descriptionController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  @override
  void didUpdateWidget(GameDetailsGameInfoTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A new game, or a scrape landing on this one, is a new description: what
    // there is to drive has to be measured again.
    _refreshDrivability();

    // A new game is a new panel: drop the gate and start its text from the
    // top. There is no language to carry over or reset any more — the panel
    // resolves one from the app's own language on every build.
    if (oldWidget.game.romPath != widget.game.romPath) {
      _isPanelActive = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _descriptionController.hasClients) {
          _descriptionController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  /// The one language this panel reads the description in.
  ///
  /// The app's own display language, mapped onto the scraper's key for it. The
  /// panel used to show every language a game had been scraped in, as a strip
  /// of chips the D-pad walked — which put a language picker in front of a
  /// user who has already told the app which language they read, on a tab
  /// whose job is to be read.
  ///
  /// Falling back is [GameModel.getDescriptionForLanguage]'s job and it
  /// already does it: the requested language, then English, then the rest of
  /// its hierarchy, then anything the game has. A game scraped in one language
  /// still shows that text rather than an empty pane.
  String _descriptionLanguage(BuildContext context) {
    final appLanguage = context
        .watch<SqliteConfigProvider>()
        .config
        .appLanguage;
    return _descriptionKeys[appLanguage] ?? appLanguage;
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.description;

    final bool showScrapeView =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    final List<Widget> headerFacts = showScrapeView || widget.isScrapingGame
        ? const []
        : _buildHeaderFacts();

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: widget.bottomOffset.r,
      // The panel is its own affordance now: its edge lights up while there
      // is something in here to drive, and a tap anywhere on it is the touch
      // equivalent of the A gate. B is still the way back out.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_isPanelActive || !_isDrivable) return;
          SfxService().playNavSound();
          enterPanel();
        },
        child: AnimatedContainer(
          duration: PanelGateHighlight.duration,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
            border: PanelGateHighlight.border(
              context,
              isDrivable: _isDrivable,
              isActive: _isPanelActive,
              restingColor: Theme.of(context).colorScheme.outline,
            ),
            boxShadow: PanelGateHighlight.shadows(
              context,
              isActive: _isPanelActive,
              resting: BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Symbols.info_rounded,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 13.r,
                        ),
                        // No title: the selected tab in the card's header strip
                        // is already this icon, so naming the panel again only
                        // costs the row room. Everything packs to the left into
                        // the space it used to take.
                        SizedBox(width: 8.r),
                        // No gate chip: the panel's own edge carries that now, so
                        // the row neither spends a slot on it nor re-packs itself
                        // on the frame the drivability answer lands. The facts
                        // strip starts at the same x on every game.
                        // The facts take the rest of the row. A long publisher
                        // name (or a system whose scrape fills every field) can
                        // outrun it, so the strip marquees when it genuinely
                        // overflows and sits still when it does not — the same
                        // treatment the footer's metadata line gets, rather than
                        // an overflow stripe or a truncated name.
                        if (headerFacts.isNotEmpty)
                          Expanded(
                            child: SizedBox(
                              height: _headerFactsHeight,
                              child: ScrollingStatusLine(
                                resetKey: widget.game.romname,
                                children: headerFacts,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Divider(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.1),
                      height: 10.r,
                    ),
                  ],
                ),
              ),

              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(8.r),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // While scraping, the card lays ScrapingProgressPanel over
                      // this whole region — every tab gets the same feedback, so
                      // this tab no longer draws its own copy.
                      return showScrapeView
                          ? _buildNonScrapedView()
                          : _buildScrapedView();
                    },
                  ),
                ),
              ),

              _buildIdentityFooter(),
            ],
          ),
        ),
      ),
    );
  }

  /// Height of one identity line. Fixed, because the marquee inside it needs a
  /// bounded box to measure its overflow against — the same reason the header's
  /// fact strip has one.
  double get _identityLineHeight => 15.r;

  /// The game's own identity, at the foot of the panel.
  ///
  /// The display name and the ROM filename underneath it. The card carries no
  /// title of its own anywhere else — the selected row in the list beside it is
  /// the title — but this panel is where a game's facts are read, and the two
  /// facts a scrape can disagree about are exactly these: what the game is
  /// called now, and what the file it came from is called. The footer's
  /// filename line only appears for scraped games, so an unscraped one had no
  /// way to see its filename at all.
  ///
  /// Either line drops out when it is empty (an Android app has no ROM), and
  /// the whole block drops out when both are, so nothing draws an empty band.
  Widget _buildIdentityFooter() {
    final String name = widget.game.name.trim();
    final String romname = widget.game.romname.trim();
    if (name.isEmpty && romname.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 0, 8.r, 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.1),
            height: 10.r,
          ),
          if (name.isNotEmpty)
            _buildIdentityLine(
              icon: Symbols.label_rounded,
              text: name,
              alpha: 0.85,
            ),
          if (name.isNotEmpty && romname.isNotEmpty) SizedBox(height: 2.r),
          if (romname.isNotEmpty)
            _buildIdentityLine(
              icon: Symbols.description_rounded,
              text: romname,
            ),
        ],
      ),
    );
  }

  /// One line of the identity block: an icon and a value that marquees when it
  /// outruns the panel's width. A ROM filename regularly does — region tags and
  /// dump flags push well past the card — and truncating it hides the end,
  /// which is the part that distinguishes two copies of the same game.
  Widget _buildIdentityLine({
    required IconData icon,
    required String text,
    double alpha = 0.6,
  }) {
    return SizedBox(
      height: _identityLineHeight,
      child: ScrollingStatusLine(
        resetKey: widget.game.romname,
        children: [
          _InfoPill(icon: icon, text: text, fontSize: 10.r, alpha: alpha),
        ],
      ),
    );
  }

  Widget _buildNonScrapedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocale.incompleteMetadata.getString(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12.r),
          SizedBox(
            width: 300.r,
            child: Text(
              AppLocale.scrapeToDownload.getString(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12.r,
                height: 1.5,
              ),
            ),
          ),
          SizedBox(height: 32.r),
          FutureBuilder<bool>(
            future: ScreenScraperService.hasSavedCredentials(),
            builder: (context, snapshot) {
              if (widget.system.folderName == 'android-apps') {
                return Text(
                  AppLocale.scrapingUnavailableAndroid.getString(context),
                  style: TextStyle(fontSize: 10.r, color: Colors.grey),
                );
              }
              final hasCredentials = snapshot.data ?? false;
              if (!hasCredentials) {
                return Text(
                  AppLocale.loginToScrape.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 10.r,
                    fontStyle: FontStyle.italic,
                  ),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  /// Height of the header's fact strip. Fixed, because the marquee inside it
  /// needs a bounded box to measure its overflow against.
  double get _headerFactsHeight => 16.r;

  /// The scraped facts, in the order they are read.
  ///
  /// Publisher and genre joined developer, players and year here when the
  /// details footer's metadata strip was removed: this panel already carried
  /// three of the five, and the strip was painting the other two onto the
  /// game's fanart on every view, one marquee'd line above the filename. All
  /// five in one place is the tab's whole job, and the strip's two are the
  /// ones a reader has to *look* for rather than glance at.
  ///
  /// Empty fields drop out entirely rather than rendering a placeholder, so an
  /// unscraped game leaves the strip empty and the row collapses.
  List<Widget> _buildHeaderFacts() {
    return [
      if (widget.game.developer.isNotEmpty)
        _InfoPill(icon: Symbols.business_rounded, text: widget.game.developer),
      if (widget.game.publisher.isNotEmpty)
        _InfoPill(
          icon: Symbols.storefront_rounded,
          text: widget.game.publisher,
        ),
      if (widget.game.players.isNotEmpty)
        _InfoPill(icon: Symbols.people_rounded, text: widget.game.players),
      if (widget.game.year.isNotEmpty)
        _InfoPill(
          icon: Symbols.calendar_today_rounded,
          text:
              RegExp(r'\d{4}').stringMatch(widget.game.year) ??
              widget.game.year,
        ),
      if (widget.game.genre.isNotEmpty)
        _InfoPill(icon: Symbols.category_rounded, text: widget.game.genre),
    ];
  }

  /// The description pane.
  ///
  /// It used to scroll itself on a timer, which meant the text was moving
  /// under the reader and there was no way to hold it still or go back a
  /// paragraph. It stays put now: a finger drags it, and the D-pad steps it
  /// once the panel has been activated.
  Widget _buildDescription(String text) {
    return SingleChildScrollView(
      controller: _descriptionController,
      physics: const BouncingScrollPhysics(),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          fontSize: 11.r,
          height: 1.6,
        ),
      ),
    );
  }

  Widget _buildScrapedView() {
    final descriptions = widget.game.descriptions;

    if (descriptions == null || descriptions.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(12.r),
        child: _buildDescription(
          GameUtils.cleanupDescription(widget.description),
        ),
      );
    }

    // One language, resolved from the app's. The strip of chips that used to
    // sit under this text is gone with it: it offered a choice the user had
    // already made in Settings, and it cost the description a band of height
    // on every game that happened to be scraped more than once.
    final activeDesc = widget.game.getDescriptionForLanguage(
      _descriptionLanguage(context),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: _buildDescription(
        GameUtils.cleanupDescription(
          activeDesc.isNotEmpty ? activeDesc : widget.description,
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  /// Text size, in the same unscaled units as everything else on the card.
  ///
  /// The header's fact strip is a row of five that has to fit one line, so it
  /// keeps the small default; the identity block at the foot is two lines of
  /// one fact each and is meant to be read rather than skimmed, so it asks for
  /// a size up.
  final double? fontSize;

  /// How strongly the line is drawn against the panel. The facts are muted
  /// chrome; the game's own name is not.
  final double alpha;

  const _InfoPill({
    required this.icon,
    required this.text,
    this.fontSize,
    this.alpha = 0.6,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: alpha);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10.r, color: color),
          SizedBox(width: 4.r),
          Text(
            text,
            style: TextStyle(fontSize: fontSize ?? 9.r, color: color),
          ),
        ],
      ),
    );
  }
}
