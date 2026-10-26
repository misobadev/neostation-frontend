import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../l10n/app_locale.dart';
import '../../../models/retro_achievement_comment.dart';
import '../../../models/secondary_achievement_item.dart';
import 'achievement_panel.dart';

/// The comment-loading state for a single achievement's comments page: the
/// filtered comment list plus paging bookkeeping and load status.
class AchievementCommentsState {
  final List<RetroAchievementComment> comments;
  final int total;

  /// Number of *raw* API results consumed so far (system comments included).
  /// The API pages over the unfiltered set, so the next fetch offset must be
  /// based on this, not on the filtered [comments] length — otherwise paging
  /// re-requests already-seen rows and "load more" appears to do nothing.
  final int loadedRaw;
  final bool isLoading;
  final String? error;

  const AchievementCommentsState({
    required this.comments,
    required this.total,
    this.loadedRaw = 0,
    this.isLoading = false,
    this.error,
  });
}

/// The achievement detail / comments page shown on the secondary display when a
/// badge is tapped: the achievement header (badge + title / points / missable
/// pill / description) above a scrollable comment thread with load-more paging.
///
/// Pure, input-driven subtree — the owning [SecondaryScreen] passes the current
/// [achievement], its cached [state] snapshot, and the load callback, so the
/// page re-reads no state of its own.
class AchievementCommentsPage extends StatelessWidget {
  const AchievementCommentsPage({
    super.key,
    required this.achievement,
    required this.state,
    required this.l10nContext,
    required this.onLoadComments,
  });

  final SecondaryAchievementItem achievement;

  /// The cached comment-loading state for [achievement], or null before the
  /// first fetch completes.
  final AchievementCommentsState? state;

  /// BuildContext captured under the MaterialApp for localized strings; falls
  /// back to the widget's own context when null.
  final BuildContext? l10nContext;

  /// Loads (or reloads, when `reset`) the comment page for `achievementId`.
  final void Function(int achievementId, {required bool reset}) onLoadComments;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    final comments = (state?.comments ?? const <RetroAchievementComment>[])
        .where((comment) => !comment.isSystemComment)
        .toList();
    final hasMore = state != null && state.loadedRaw < state.total;

    return Container(
      color: Colors.black,
      padding: EdgeInsets.fromLTRB(58.r, 20.r, 24.r, 20.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              buildAchievementBadge(achievement, isNew: false),
              SizedBox(width: 14.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            achievement.title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18.r,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Anta',
                            ),
                          ),
                        ),
                        if (achievement.isMissable)
                          Center(
                            child: buildMissablePill(
                              context,
                              l10nContext: l10nContext,
                            ),
                          ),
                        SizedBox(width: 10.r),
                        Text(
                          '${achievement.points} '
                          '${AppLocale.raPointsAbbrev.getString(l10nContext ?? context)}',
                          style: TextStyle(
                            color: const Color(0xFFFFC107),
                            fontSize: 15.r,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Anta',
                          ),
                        ),
                      ],
                    ),
                    if (achievement.description.isNotEmpty) ...[
                      SizedBox(height: 4.r),
                      Text(
                        achievement.description,
                        style: TextStyle(color: Colors.white60, fontSize: 12.r),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16.r),
          Text(
            AppLocale.raComments.getString(l10nContext ?? context),
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12.r,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2.r,
              fontFamily: 'Anta',
            ),
          ),
          SizedBox(height: 8.r),
          Expanded(
            child: state == null || (state.isLoading && comments.isEmpty)
                ? const Center(child: CircularProgressIndicator())
                : state.error != null && comments.isEmpty
                ? _buildCommentsMessage(
                    AppLocale.raCommentsCouldNotLoad.getString(
                      l10nContext ?? context,
                    ),
                    actionLabel: AppLocale.retry
                        .getString(l10nContext ?? context)
                        .toUpperCase(),
                    onAction: () => onLoadComments(achievement.id, reset: true),
                  )
                : comments.isEmpty
                ? _buildCommentsMessage(
                    AppLocale.raNoCommentsYet.getString(l10nContext ?? context),
                  )
                : ListView.separated(
                    itemCount: comments.length + (hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => SizedBox(height: 8.r),
                    itemBuilder: (context, index) {
                      if (index == comments.length) {
                        return _buildLoadMoreComments(
                          context,
                          achievement.id,
                          state,
                        );
                      }
                      return _buildCommentCard(context, comments[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentCard(
    BuildContext context,
    RetroAchievementComment comment,
  ) {
    return Container(
      padding: EdgeInsets.all(10.r),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  comment.user.isEmpty
                      ? AppLocale.unknownUser.getString(l10nContext ?? context)
                      : comment.user,
                  style: TextStyle(
                    color: const Color(0xFFFFC107),
                    fontSize: 12.r,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (comment.submitted != null)
                Text(
                  _formatCommentDate(comment.submitted!),
                  style: TextStyle(color: Colors.white38, fontSize: 10.r),
                ),
            ],
          ),
          SizedBox(height: 5.r),
          Text(
            comment.commentText,
            style: TextStyle(color: Colors.white70, fontSize: 12.r),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreComments(
    BuildContext context,
    int achievementId,
    AchievementCommentsState state,
  ) {
    if (state.isLoading) {
      return Padding(
        padding: EdgeInsets.all(12.r),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return _buildCommentsMessage(
      state.error ??
          AppLocale.raOlderCommentsAvailable.getString(l10nContext ?? context),
      actionLabel: state.error == null
          ? AppLocale.raLoadMore.getString(l10nContext ?? context)
          : AppLocale.retry.getString(l10nContext ?? context).toUpperCase(),
      onAction: () => onLoadComments(achievementId, reset: false),
    );
  }

  Widget _buildCommentsMessage(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            style: TextStyle(color: Colors.white54, fontSize: 13.r),
          ),
          if (actionLabel != null && onAction != null) ...[
            SizedBox(height: 10.r),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }

  String _formatCommentDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
