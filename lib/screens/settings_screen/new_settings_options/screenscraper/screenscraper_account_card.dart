import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The signed-in ScreenScraper member: name, contribution tier, thread
/// allowance, daily request quota, and the logout control.
class ScreenScraperAccountCard extends StatelessWidget {
  /// Whether the gamepad cursor is on the logout control.
  final bool logoutFocused;
  final Map<String, String>? userInfo;
  final VoidCallback onLogout;

  const ScreenScraperAccountCard({
    super.key,
    required this.logoutFocused,
    required this.userInfo,
    required this.onLogout,
  });

  String _getContributionLevel(BuildContext context, String? contribution) {
    if (contribution == null || contribution.isEmpty) {
      return AppLocale.noData.getString(context);
    }
    switch (contribution) {
      case '0':
        return AppLocale.free.getString(context);
      case '1':
        return AppLocale.bronze.getString(context);
      case '2':
        return AppLocale.silver.getString(context);
      case '3':
        return AppLocale.gold.getString(context);
      case '15':
        return AppLocale.developer.getString(context);
      default:
        return AppLocale.member.getString(context);
    }
  }

  Color _getContributionColor(String? contribution, Color fallback) {
    switch (contribution) {
      case '1':
        return const Color(0xFFCD7F32);
      case '2':
        return const Color(0xFFC0C0C0);
      case '3':
        return const Color(0xFFFFD700);
      default:
        // Base "Member" tier: follow the theme accent (like the RA tab's
        // user-type pill) instead of an off-palette blue-grey.
        return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasExtendedInfo =
        userInfo != null && userInfo!['requests_today'] != null;

    if (userInfo == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Full-width member header pill (avatar + name + chips + logout)
        _buildMemberHeader(context, theme),

        // Total Requests Section (Below, smaller)
        if (hasExtendedInfo) ...[
          SizedBox(height: 8.r),
          _buildSmallQuotaCard(
            theme,
            AppLocale.dailyTotalRequests.getString(context),
            int.tryParse(userInfo!['requests_today'] ?? '0') ?? 0,
            int.tryParse(userInfo!['max_requests_per_day'] ?? '0') ?? 1,
            theme.colorScheme.primary,
          ),
        ],
      ],
    );
  }

  Widget _buildMemberHeader(BuildContext context, ThemeData theme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 12.r),
      decoration: _cardDecoration(theme),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24.r,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
            child: Text(
              (userInfo!['username'] ?? 'U').substring(0, 1).toUpperCase(),
              style: TextStyle(
                fontSize: 18.r,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 12.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userInfo!['username'] ??
                      AppLocale.unknownUser.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.r,
                  ),
                ),
                SizedBox(height: 4.r),
                Wrap(
                  spacing: 8.r,
                  runSpacing: 6.r,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildPill(
                      icon: Symbols.workspace_premium_rounded,
                      label: _getContributionLevel(
                        context,
                        userInfo!['contribution'],
                      ),
                      color: _getContributionColor(
                        userInfo!['contribution'],
                        theme.colorScheme.primary,
                      ),
                    ),
                    _buildPill(
                      icon: Symbols.lan_rounded,
                      label:
                          '${AppLocale.maxThreads.getString(context)}: ${userInfo!['maxthreads'] ?? '1'}',
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          _buildLogoutButton(context, theme),
        ],
      ),
    );
  }

  /// The border keeps this in step with the other option lists, and with the
  /// RA dashboard's logout, so a destructive slot reads the same way on both
  /// accounts.
  Widget _buildLogoutButton(BuildContext context, ThemeData theme) {
    final selected = logoutFocused;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: IconButton(
        onPressed: onLogout,
        icon: Icon(
          Symbols.logout_rounded,
          size: 20.r,
          color: theme.colorScheme.error,
        ),
        tooltip: AppLocale.disconnectAccount.getString(context),
      ),
    );
  }

  BoxDecoration _cardDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.cardColor.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(12.r),
      border: Border.all(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        width: 1.r,
      ),
    );
  }

  Widget _buildPill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999.r),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10.r, color: color),
          SizedBox(width: 4.r),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 8.r,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallQuotaCard(
    ThemeData theme,
    String label,
    int current,
    int max,
    Color color,
  ) {
    final progress = (max > 0) ? (current / max).clamp(0.0, 1.0) : 0.0;
    final percentage = (progress * 100).toInt();

    return Container(
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 10.sp,
                ),
              ),
              Text(
                '$current / $max ($percentage%)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 10.sp,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          ClipRRect(
            borderRadius: BorderRadius.circular(2.r),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: color.withValues(alpha: 0.05),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 4.h,
            ),
          ),
        ],
      ),
    );
  }
}
