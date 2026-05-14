import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';

class AccountContent extends StatelessWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final Map<String, String>? userInfo;
  final VoidCallback onLogout;

  const AccountContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
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

  Color _getContributionColor(String? contribution) {
    switch (contribution) {
      case '1':
        return const Color(0xFFCD7F32);
      case '2':
        return const Color(0xFFC0C0C0);
      case '3':
        return const Color(0xFFFFD700);
      default:
        return Colors.blueGrey;
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

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(title: AppLocale.screenscraper.getString(context)),
          SizedBox(height: 12.r),

          // Row for Username (50%) and Max Threads (50%)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // User Information (50%)
              Expanded(flex: 1, child: _buildCompactUserHeader(context, theme)),
              SizedBox(width: 12.r),
              // Max Threads (50%)
              Expanded(
                flex: 1,
                child: _buildCompactStatTile(
                  theme,
                  AppLocale.maxThreads.getString(context),
                  userInfo!['maxthreads'] ?? '1',
                  Symbols.lan_rounded,
                ),
              ),
            ],
          ),

          SizedBox(height: 12.h),

          // Total Requests Section (Below, smaller)
          if (hasExtendedInfo) ...[
            _buildSmallQuotaCard(
              theme,
              AppLocale.dailyTotalRequests.getString(context),
              int.tryParse(userInfo!['requests_today'] ?? '0') ?? 0,
              int.tryParse(userInfo!['max_requests_per_day'] ?? '0') ?? 1,
              theme.colorScheme.primary,
            ),
            SizedBox(height: 16.h),
          ],

          // Disconnect Button
          Padding(
            padding: EdgeInsets.only(bottom: 24.r),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: isContentFocused && selectedContentIndex == 0
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2.r,
                ),
              ),
              child: ElevatedButton.icon(
                onPressed: onLogout,
                icon: Icon(Symbols.logout_rounded, size: 14.r, color: Colors.white),
                label: Text(
                  AppLocale.disconnectAccount.getString(context),
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.error,
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.r,
                    vertical: 16.r,
                  ),
                  side: BorderSide(color: theme.colorScheme.error),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactUserHeader(BuildContext context, ThemeData theme) {
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
      child: Row(
        children: [
          CircleAvatar(
            radius: 18.r,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
            child: Text(
              (userInfo!['username'] ?? 'U').substring(0, 1).toUpperCase(),
              style: TextStyle(
                fontSize: 14.r,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  userInfo!['username'] ??
                      AppLocale.unknownUser.getString(context),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.r,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2.r),
                _buildBadge(
                  _getContributionLevel(context, userInfo!['contribution']),
                  _getContributionColor(userInfo!['contribution']),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactStatTile(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
  ) {
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
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(12.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: theme.colorScheme.secondary, size: 14.r),
          ),
          SizedBox(width: 8.r),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 12.r,
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 11.sp,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4.r),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8.sp,
          fontWeight: FontWeight.bold,
        ),
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
