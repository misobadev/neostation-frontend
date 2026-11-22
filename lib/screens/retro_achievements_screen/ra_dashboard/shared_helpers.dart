part of '../ra_dashboard.dart';

/// Shared building blocks for the dashboard cards: section headers, pills,
/// loading/empty/error section bodies, thumbnails, card decoration, media
/// URLs, and date formatting.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged.
extension _SharedHelpers on RADashboardHubState {
  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? trailing,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 15.r, color: theme.colorScheme.primary),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
              fontSize: 10.r,
            ),
          ),
        ),
        if (trailing != null && trailing.isNotEmpty)
          Text(
            trailing,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 8.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
            ),
          ),
      ],
    );
  }

  Widget _buildLoadingState(BuildContext context, {required double minHeight}) {
    final theme = Theme.of(context);
    return SizedBox(
      height: minHeight,
      child: Center(
        child: SizedBox(
          width: 22.r,
          height: 22.r,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionMessage(
    BuildContext context,
    String message, {
    bool isError = false,
    Future<bool> Function()? onRetry,
    required double minHeight,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: minHeight,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: 8.r),
              TextButton(
                onPressed: () => onRetry(),
                child: Text(AppLocale.retry.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration(
    ThemeData theme, {
    Color? background,
    Color? borderColor,
    double? borderWidth,
  }) {
    // The overview's sections sit straight on the panel: no fill and no
    // edge at rest (a card inside the panel's card read as boxed in), and
    // only the selected one is outlined.
    return BoxDecoration(
      color: background ?? Colors.transparent,
      borderRadius:
          theme.extension<CornerRadii>()?.radiusInternal ??
          BorderRadius.circular(10.r),
      border: Border.all(
        color: borderColor ?? Colors.transparent,
        width: borderWidth ?? 1.r,
      ),
    );
  }

  String _raMediaUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return 'https://media.retroachievements.org$path';
  }

  String _formatDate(String raw) {
    if (raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
