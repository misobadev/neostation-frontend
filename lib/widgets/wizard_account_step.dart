import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The body of one of the setup wizard's optional account steps
/// (RetroAchievements, RomM, metadata, save syncing): what the service is for,
/// and whether it is set up yet.
///
/// The sign-in itself happens in the service's own form, opened on a page of
/// its own by [pushWizardServicePage]; this only describes the step.
class WizardAccountStep extends StatelessWidget {
  const WizardAccountStep({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.signedInAs,
    this.skipNote,
  });

  final IconData icon;
  final String title;
  final String description;

  /// Who the service is signed in as, or null while it is not set up.
  final String? signedInAs;

  /// What skipping costs, when that is more than "do it later in Settings"
  /// (RomM and save syncing hide their tabs when skipped).
  final String? skipNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;
    final signedIn = signedInAs != null;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            signedIn ? Symbols.check_circle_rounded : icon,
            size: iconSize,
            color: signedIn ? Colors.green : theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),
          Text(
            title,
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            description,
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 12.r : 28.r),
          if (signedIn)
            _StatusPill(
              icon: Symbols.check_circle_rounded,
              color: Colors.green,
              text: AppLocale.wizardSignedInAs
                  .getString(context)
                  .replaceFirst('{name}', signedInAs!),
              textSize: textSize,
            )
          else
            Text(
              skipNote ?? AppLocale.wizardAccountLater.getString(context),
              style: TextStyle(
                fontSize: textSize - 1.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.color,
    required this.text,
    required this.textSize,
  });

  final IconData icon;
  final Color color;
  final String text;
  final double textSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: textSize + 6.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: textSize, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which tabs a new user's setup leaves hidden: RomM's when no server was
/// connected, and Saves' when no save syncing was set up — NeoSync, or RomM
/// while it is the save provider. Both can be turned back on in Settings.
({bool hideRomm, bool hideSaves}) tabsHiddenAfterSetup({
  required bool rommConnected,
  required bool neoSyncSignedIn,
  required bool savesUseRomm,
}) => (
  hideRomm: !rommConnected,
  hideSaves: !(neoSyncSignedIn || (savesUseRomm && rommConnected)),
);

/// Opens a service's own sign-in form on a page of its own, over the wizard,
/// and closes it once [isDone] reports the service set up.
///
/// [builder] receives the close callback to hand the form as its B / back
/// action. [listenable] is what changes when the service signs in (its
/// provider); the page watches it so a successful sign-in returns to the
/// wizard without the user having to back out. Resolves when the page closes,
/// either way.
///
/// The forms push their own gamepad layers, so the caller pauses its own
/// navigation around this call.
Future<void> pushWizardServicePage(
  BuildContext context, {
  required Widget Function(VoidCallback close) builder,
  required Listenable listenable,
  required bool Function() isDone,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _WizardServicePage(
        builder: builder,
        listenable: listenable,
        isDone: isDone,
      ),
    ),
  );
}

class _WizardServicePage extends StatefulWidget {
  const _WizardServicePage({
    required this.builder,
    required this.listenable,
    required this.isDone,
  });

  final Widget Function(VoidCallback close) builder;
  final Listenable listenable;
  final bool Function() isDone;

  @override
  State<_WizardServicePage> createState() => _WizardServicePageState();
}

class _WizardServicePageState extends State<_WizardServicePage> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (widget.isDone()) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(child: widget.builder(_close)),
    );
  }
}
