import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../services/music_player_service.dart';
import '../../../utils/game_utils.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/music_visualizer.dart';
import 'package:neostation/l10n/app_locale.dart';

/// A specialized media player component designed for high-fidelity audio playback and visualization.
///
/// Orchestrates background audio services, dynamic metadata resolution, and
/// hardware-mapped gamepad controls. Features a performance-optimized seek bar
/// and integrated music visualization.
class MusicPlayer extends StatefulWidget {
  final Color systemColor;
  final VoidCallback? onFavoriteToggled;
  final VoidCallback? onBack;

  const MusicPlayer({
    super.key,
    required this.systemColor,
    this.onFavoriteToggled,
    this.onBack,
  });

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayer> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12.r),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.25),
            width: 1.2.r,
          ),
        ),
        padding: EdgeInsets.all(6.r),
        child: Column(
          children: [
            // Upper Section: Visualization and Transport Controls.
            Expanded(
              child: ListenableBuilder(
                listenable: MusicPlayerService(),
                builder: (context, _) {
                  final service = MusicPlayerService();
                  final isPlaying = service.isPlaying;
                  final isLooping = service.isLooping;
                  final isShuffle = service.isShuffle;

                  return Stack(
                    children: [
                      // Active Frequency Visualizer.
                      Positioned.fill(
                        child: MusicVisualizer(
                          isPlaying: isPlaying,
                          volume: service.volume,
                        ),
                      ),

                      // Transport Control Overlay: Mapped to standard Gamepad layout.
                      Positioned(
                        bottom: 0.r,
                        right: 0.r,
                        child: Center(
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 5.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).scaffoldBackgroundColor.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12.r),
                              boxShadow: [
                                BoxShadow(
                                  color: Theme.of(context)
                                      .scaffoldBackgroundColor
                                      .withValues(alpha: 0.2),
                                  blurRadius: 8.r,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Action: Termination / Navigation Back (B Button).
                                if (widget.onBack != null) ...[
                                  _GamepadActionBtn(
                                    gamepadIcon:
                                        'assets/images/gamepad/Xbox_B_button.png',
                                    label: AppLocale.back.getString(context),
                                    onTap: () {
                                      SfxService().playBackSound();
                                      widget.onBack!();
                                    },
                                    isActive: false,
                                    tooltip: AppLocale.back.getString(context),
                                  ),
                                  SizedBox(width: 8.r),
                                ],

                                // Action: Shuffle / Random Playback (View Button).
                                _GamepadActionBtn(
                                  gamepadIcon:
                                      'assets/images/gamepad/Xbox_View_button.png',
                                  symbol: isShuffle
                                      ? Symbols.shuffle_on_rounded
                                      : Symbols.shuffle_rounded,
                                  onTap: () {
                                    SfxService().playNavSound();
                                    service.toggleShuffle();
                                  },
                                  isActive: isShuffle,
                                  tooltip: AppLocale.random.getString(context),
                                ),
                                SizedBox(width: 8.r),

                                // Action: Loop Mode Toggle (X Button).
                                _GamepadActionBtn(
                                  gamepadIcon:
                                      'assets/images/gamepad/Xbox_X_button.png',
                                  symbol:
                                      isLooping && service.isCurrentTrackLooping
                                      ? Symbols.repeat_one_rounded
                                      : Symbols.repeat_rounded,
                                  onTap: () {
                                    SfxService().playNavSound();
                                    service.setLoop(
                                      !service.isCurrentTrackLooping,
                                    );
                                  },
                                  isActive:
                                      isLooping &&
                                      service.isCurrentTrackLooping,
                                  tooltip: AppLocale.loop.getString(context),
                                ),
                                SizedBox(width: 8.r),

                                // Primary Action: Play/Pause State Arbitration (A Button).
                                _GamepadActionBtn(
                                  gamepadIcon:
                                      'assets/images/gamepad/Xbox_A_button.png',
                                  symbol:
                                      (isPlaying &&
                                          service.activeTrack?.romPath ==
                                              service.currentTrack?.romPath)
                                      ? Symbols.pause_rounded
                                      : Symbols.play_arrow_rounded,
                                  onTap: () {
                                    final isHearingCurrent =
                                        service.activeTrack?.romPath ==
                                        service.currentTrack?.romPath;

                                    if (isPlaying && isHearingCurrent) {
                                      SfxService().playBackSound();
                                      service.pause();
                                    } else {
                                      if (isHearingCurrent &&
                                          service.isStarted) {
                                        SfxService().playEnterSound();
                                        service.resume();
                                      } else {
                                        SfxService().playEnterSound();
                                        service.start(
                                          index: service.currentIndex,
                                        );
                                      }
                                    }
                                  },
                                  isActive:
                                      isPlaying &&
                                      service.activeTrack?.romPath ==
                                          service.currentTrack?.romPath,
                                  isLarge: true,
                                  tooltip:
                                      (isPlaying &&
                                          service.activeTrack?.romPath ==
                                              service.currentTrack?.romPath)
                                      ? AppLocale.pause.getString(context)
                                      : AppLocale.play.getString(context),
                                ),
                                SizedBox(width: 8.r),

                                // Action: Library Favorite Toggle (Y Button).
                                _GamepadActionBtn(
                                  gamepadIcon:
                                      'assets/images/gamepad/Xbox_Y_button.png',
                                  symbol:
                                      service.currentTrack?.isFavorite == true
                                      ? Symbols.favorite_rounded
                                      : Symbols.favorite_border_rounded,
                                  onTap: () async {
                                    SfxService().playNavSound();
                                    final configProvider = context
                                        .read<SqliteConfigProvider>();
                                    await service.toggleFavorite();
                                    if (mounted) {
                                      await configProvider
                                          .refreshDetectedSystems();
                                      widget.onFavoriteToggled?.call();
                                    }
                                  },
                                  isActive:
                                      service.currentTrack?.isFavorite == true,
                                  activeColor: Colors.redAccent,
                                  tooltip: AppLocale.favorite.getString(
                                    context,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: 12.r),

            // Lower Section: Metadata Display and Seek Interface.
            ListenableBuilder(
              listenable: MusicPlayerService(),
              builder: (context, _) {
                final service = MusicPlayerService();
                final currentTrack = service.currentTrack;
                final isPlaying = service.isPlaying;

                // Title Resolution: Metadata Tags > ROM Filename > Fallback.
                final trackTitle =
                    service.currentTitle ??
                    (currentTrack != null
                        ? GameUtils.formatGameName(
                            currentTrack.titleName ?? currentTrack.realname,
                          )
                        : AppLocale.noTrackSelected.getString(context));

                // Artist/Developer Resolution.
                final artist =
                    service.currentArtist ??
                    ((currentTrack?.developer.isNotEmpty == true)
                        ? currentTrack!.developer
                        : null);
                final album = service.currentAlbum;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Identity Layout: Cover art and text fields.
                    Row(
                      children: [
                        Container(
                          width: 56.r,
                          height: 56.r,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8.r),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.2),
                              width: 1.0,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8.r),
                            child:
                                (service.currentPicture ??
                                        service.activePicture) !=
                                    null
                                ? Image.memory(
                                    (service.currentPicture ??
                                        service.activePicture)!,
                                    key: ValueKey(
                                      service.currentTrack?.romPath ??
                                          service.activeTrack?.romPath,
                                    ),
                                    fit: BoxFit.cover,
                                  )
                                : Icon(
                                    Symbols.music_note_rounded,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 20.r,
                                  ),
                          ),
                        ),
                        SizedBox(width: 12.r),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MarqueeText(
                                text: trackTitle,
                                isActive: isPlaying,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 13.r,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (artist != null && artist.isNotEmpty)
                                MarqueeText(
                                  text: artist,
                                  isActive: isPlaying,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.9),
                                    fontSize: 10.r,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              if (album != null && album.isNotEmpty)
                                MarqueeText(
                                  text: album,
                                  isActive: isPlaying,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.7),
                                    fontSize: 9.r,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: 4.r),

                    // Playback Progress: Isolated for high-frequency updates.
                    _SeekBar(key: ValueKey(service.currentIndex)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A specialized slider component that manages high-frequency stream subscriptions for seek state.
class _SeekBar extends StatefulWidget {
  const _SeekBar({super.key});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    final service = MusicPlayerService();

    // Initial State Fetch.
    service.position.then((p) {
      if (mounted) setState(() => _position = p);
    });
    service.duration.then((d) {
      if (mounted) setState(() => _duration = d);
    });

    // Real-time Stream Listeners.
    _posSub = service.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = service.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(duration.inMinutes.remainder(60))}:${pad(duration.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dimText = scheme.onSurface.withValues(alpha: 0.45);
    final totalSecs = _duration.inSeconds.toDouble();
    final posSecs = _position.inSeconds.toDouble();
    final sliderMax = totalSecs > 0 ? totalSecs : 1.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.r,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5.r),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 10.r),
            activeTrackColor: Theme.of(context).colorScheme.primary,
            inactiveTrackColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            thumbColor: Theme.of(context).colorScheme.primary,
            overlayColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
          ),
          child: SizedBox(
            height: 24.r,
            child: Slider(
              value: posSecs.clamp(0, sliderMax),
              min: 0,
              max: sliderMax,
              onChanged: (val) {
                MusicPlayerService().seek(Duration(seconds: val.toInt()));
              },
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4.r),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: TextStyle(color: dimText, fontSize: 8.5.r),
              ),
              Text(
                _formatDuration(_duration),
                style: TextStyle(color: dimText, fontSize: 8.5.r),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A button specialized for the Music Player that features a hardware gamepad icon and playback symbol.
class _GamepadActionBtn extends StatelessWidget {
  final String gamepadIcon;
  final IconData? symbol;
  final String? label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? activeColor;
  final bool isLarge;
  final String? tooltip;

  const _GamepadActionBtn({
    required this.gamepadIcon,
    this.symbol,
    this.label,
    required this.onTap,
    this.isActive = false,
    this.activeColor,
    this.isLarge = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;

    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            SfxService().playNavSound();
            onTap();
          },
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 8.r,
              vertical: isLarge ? 6.r : 4.r,
            ),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).scaffoldBackgroundColor.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: onSurface.withValues(alpha: 0.4),
                width: 1.r,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  gamepadIcon,
                  width: isLarge ? 16.r : 14.r,
                  height: isLarge ? 16.r : 14.r,
                  color: onSurface,
                ),
                SizedBox(width: 6.r),
                if (label != null)
                  Text(
                    label!,
                    style: TextStyle(
                      color: isActive ? (activeColor ?? primary) : onSurface,
                      fontSize: isLarge ? 12.r : 10.r,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                else if (symbol != null)
                  Icon(
                    symbol!,
                    size: isLarge ? 18.r : 14.r,
                    color: isActive ? (activeColor ?? primary) : onSurface,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
