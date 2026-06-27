import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/responsive.dart';
import '../../../providers/sqlite_config_provider.dart';

/// A premium introductory widget presented when no ROM library is configured.
///
/// Facilitates the initial filesystem handshake, allowing users to select
/// their root ROM directory and initiate the first automated system scan.
class InitialSetupWidget extends StatelessWidget {
  const InitialSetupWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        // SCENARIO A: Compact Handheld Layouts (XS/Small).
        // Prioritizes a single-column ROM selection interface.
        if (Responsive.isHandheldXS(context) ||
            Responsive.isHandheldSmall(context)) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            child: Center(
              child: _buildRomSelectionSection(context, configProvider),
            ),
          );
        }

        // SCENARIO B: Desktop / Large Handheld Layouts (Medium+).
        // Displays a split-view with action (ROM selection) and education (Help card).
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Left Column: Primary Action (Library Setup).
                  Expanded(
                    flex: 1,
                    child: _buildRomSelectionSection(context, configProvider),
                  ),
                  const SizedBox(width: 16),
                  // Right Column: System Documentation / Guidance.
                  Expanded(flex: 1, child: _buildHelpCard(context)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Builds the core setup card containing branding and the directory picker trigger.
  Widget _buildRomSelectionSection(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    final theme = Theme.of(context);

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(32.0),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Premium branding iconography with glow effects.
              Container(
                padding: const EdgeInsets.all(20.0),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    width: 2,
                  ),
                ),
                child: SizedBox(
                  width: 60,
                  height: 60,
                  child: Image.asset(
                    'assets/images/icons/folder-add-bulk.png',
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Text(
                AppLocale.setupLibrary.getString(context),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  fontSize: 28,
                  letterSpacing: -0.5,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 12),

              Text(
                AppLocale.chooseRomFolderOrganize.getString(context),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  fontSize: 15,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 32),

              // Dynamic button state based on scan or initialization progress.
              if (configProvider.isLoading || configProvider.isScanning)
                _buildLoadingButton(context)
              else
                _buildSelectButton(context, configProvider),

              const SizedBox(height: 24),

              // Feedback layer for errors or successful initial resolution.
              if (configProvider.error != null)
                _buildErrorMessage(context, configProvider.error!)
              else if (configProvider.hasRomFolder &&
                  !configProvider.isScanning)
                _buildSuccessMessage(context, configProvider),
            ],
          ),
        ),
      ),
    );
  }

  /// Specialized button state for active filesystem scanning.
  Widget _buildLoadingButton(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.primary.withValues(alpha: 0.3),
      ),
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              AppLocale.scanningButton.getString(context),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Primary interaction button for directory selection.
  Widget _buildSelectButton(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    final theme = Theme.of(context);
    final hasFolder = configProvider.hasRomFolder;

    return Container(
      width: double.infinity,
      height: 64,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => configProvider.selectRomFolder(context: context),
          borderRadius: BorderRadius.circular(18),
          child: Center(
            child: Text(
              hasFolder
                  ? AppLocale.changeFolder.getString(context)
                  : AppLocale.selectRomFolderButton.getString(context),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Renders a localized error feedback message.
  Widget _buildErrorMessage(BuildContext context, String error) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Image.asset(
              'assets/images/icons/warning-bulk.png',
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              error,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Success message indicating a valid library handshake.
  Widget _buildSuccessMessage(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Image.asset(
                  'assets/images/icons/check-bulk.png',
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  AppLocale.configurationComplete.getString(context),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AppLocale.foundSystemsInFolder
                .getString(context)
                .replaceFirst(
                  '{count}',
                  configProvider.detectedRealSystems.length.toString(),
                ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          if (configProvider.config.lastScan != null) ...[
            const SizedBox(height: 4),
            Text(
              AppLocale.lastScanLabel
                  .getString(context)
                  .replaceFirst(
                    '{date}',
                    _formatDateTime(configProvider.config.lastScan!),
                  ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Educational card explaining the automated scanning workflow.
  Widget _buildHelpCard(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.666),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Image.asset(
                      'assets/images/icons/lightbulb-bulk.png',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppLocale.howItWorks.getString(context),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpItem(
                context,
                AppLocale.step1SelectFolder.getString(context),
                AppLocale.step1Desc.getString(context),
              ),
              _buildHelpItem(
                context,
                AppLocale.step2AutoDetection.getString(context),
                AppLocale.step2Desc.getString(context),
              ),
              _buildHelpItem(
                context,
                AppLocale.step3CountGames.getString(context),
                AppLocale.step3Desc.getString(context),
              ),
              _buildHelpItem(
                context,
                AppLocale.step4ReadyToPlay.getString(context),
                AppLocale.step4Desc.getString(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Utilitarian item for help card step lists.
  Widget _buildHelpItem(
    BuildContext context,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// Utilitarian date formatter for localized setup timestamps.
  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
