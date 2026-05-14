import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/music_player_service.dart';
import 'package:neostation/widgets/custom_notification.dart';

class MusicNotificationListener extends StatefulWidget {
  final Widget child;

  const MusicNotificationListener({super.key, required this.child});

  @override
  State<MusicNotificationListener> createState() =>
      _MusicNotificationListenerState();
}

class _MusicNotificationListenerState extends State<MusicNotificationListener> {
  final MusicPlayerService _service = MusicPlayerService();
  String? _lastNotifiedPath;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    final currentPath = _service.activeTrack?.romPath;

    // Only notify if it is PLAYING, the active track has changed, and we have an active title
    if (_service.isPlaying &&
        currentPath != null &&
        currentPath != _lastNotifiedPath &&
        _service.activeTitle != null) {
      _lastNotifiedPath = currentPath;

      // Show notification using ACTIVE metadata
      AppNotification.showNotification(
        context,
        "${_service.activeTitle} • ${_service.activeArtist ?? AppLocale.unknownArtist.getString(context)}",
        title: AppLocale.nowPlaying.getString(context),
        imageBytes: _service.activePicture,
        icon: Symbols.music_note_rounded,
        notificationId: 'music_change',
        duration: const Duration(seconds: 4),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
