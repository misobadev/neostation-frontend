import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/sqlite_config_provider.dart';
import 'setup_wizard.dart';
import 'splash_status_layout.dart';

/// Widget that checks the initial configuration and shows the wizard if necessary
class PermissionCheckWrapper extends StatefulWidget {
  final Widget child;

  static const String setupCompletedKey = 'setup_completed_prefs';

  const PermissionCheckWrapper({super.key, required this.child});

  @override
  State<PermissionCheckWrapper> createState() => _PermissionCheckWrapperState();
}

class _PermissionCheckWrapperState extends State<PermissionCheckWrapper> {
  bool _needsSetup = false;
  bool _isChecking = true;

  static final _log = LoggerService.instance;

  @override
  void initState() {
    super.initState();

    // Check whether initial configuration is needed
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialSetup();
    });
  }

  static const String setupCompletedKey = 'setup_completed_prefs';

  Future<void> _checkInitialSetup() async {
    try {
      // Fast-path: SharedPreferences flag survives SD-card unavailability and
      // early-launcher boot races. If set, skip the wizard unconditionally.
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(PermissionCheckWrapper.setupCompletedKey) == true) {
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _isChecking = false;
        });
        return;
      }

      if (!mounted) return;
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );

      if (!configProvider.initialized) {
        await configProvider.initialize();
      }

      final hasRomFolder = configProvider.config.romFolder?.isNotEmpty == true;
      final setupCompleted = configProvider.config.setupCompleted;

      if (hasRomFolder || setupCompleted) {
        // Backfill the SharedPreferences flag for existing users upgrading.
        await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
        _pushWizardActive(false);
        setState(() {
          _needsSetup = false;
          _isChecking = false;
        });
      } else {
        _pushWizardActive(true);
        setState(() {
          _needsSetup = true;
          _isChecking = false;
        });
      }
    } catch (e) {
      _log.e('Error checking initial setup: $e');
      _pushWizardActive(false);
      setState(() {
        _needsSetup = false;
        _isChecking = false;
      });
    }
  }

  /// Mirrors "the wizard is on screen" to the secondary display, which parks
  /// its app dock and launcher while setup runs. Pushed from here — the single
  /// place that decides whether the wizard shows — so a normal boot also clears
  /// a flag left behind by a run that was killed mid-wizard.
  void _pushWizardActive(bool active) {
    if (!mounted) return;
    Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).setSetupWizardActive(active);
  }

  Future<void> _completeSetup() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    // A failure here reaches the wizard, which says so and lets the user try
    // again.
    await configProvider.completeSetup();

    // Setup is done — let the secondary display bring in the dock/launcher.
    configProvider.setSetupWizardActive(false);

    // Persist flag to SharedPreferences so the wizard is never shown again
    // even if the SQLite DB is temporarily inaccessible (e.g. SD card not ready).
    // Setup is already saved as completed in the database, which restores
    // this flag at the next start if it can't be written now.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(setupCompletedKey, true);
    } catch (e) {
      _log.w('Could not save the setup flag to preferences: $e');
    }

    if (!mounted) return;
    setState(() {
      _needsSetup = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      // Show loading while checking — same shimmering logo as the rest of the
      // startup chain, so this gate doesn't read as a separate plain screen.
      // Laid out by SplashStatusLayout (with no status block) rather than a
      // bare centred logo: that keeps the glyph at the same size and centre as
      // the screens on either side of this gate, so it doesn't jump.
      return const Scaffold(body: SplashStatusLayout(children: []));
    }

    if (_needsSetup) {
      // Show configuration wizard
      return SetupWizard(onComplete: _completeSetup);
    }

    // Show the normal app
    return widget.child;
  }
}
