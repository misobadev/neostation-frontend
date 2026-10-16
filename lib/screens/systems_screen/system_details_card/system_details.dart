import 'package:neostation/constants/system_folder_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../../models/system_model.dart';

/// A premium informational sidebar component displaying system metadata.
///
/// Dynamically renders hardware descriptions, launch dates, and ROM counts
/// based on the currently hovered or selected system in the main grid.
class SystemDetails extends StatefulWidget {
  const SystemDetails({super.key, this.selectedSystem});

  final SystemModel? selectedSystem;

  @override
  SystemDetailsState createState() => SystemDetailsState();
}

class SystemDetailsState extends State<SystemDetails> {
  /// Renders hardware statistics and technical descriptions for a specific system.
  Widget _buildSystemStats(BuildContext context) {
    // Special branding for the 'ALL' (Global Library) view.
    final isAllSystem =
        widget.selectedSystem!.folderName.toLowerCase() == 'all';
    const neoStationDescription =
        'NeoStation is your ultimate hub for classic games. Relive the nostalgia and rediscover gaming history.';

    return Column(
      children: [
        // Content Area: Prioritize hardware description or global branding.
        if (isAllSystem ||
            (widget.selectedSystem!.description != null &&
                widget.selectedSystem!.description!.isNotEmpty)) ...[
          Expanded(
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.1),
                  width: 1.r,
                ),
              ),
              child: Text(
                isAllSystem
                    ? neoStationDescription
                    : widget.selectedSystem!.description!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.8),
                  fontSize: 11.r,
                ),
                maxLines: 7,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ] else ...[
          // Fallback view: Displays ROM count badge if no detailed description is found.
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(16.r),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  widget.selectedSystem!.colorAsColor.withValues(alpha: 0.1),
                  widget.selectedSystem!.colorAsColor.withValues(alpha: 0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: widget.selectedSystem!.colorAsColor.withValues(
                  alpha: 0.2,
                ),
                width: 1.r,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.r,
                    vertical: 6.r,
                  ),
                  decoration: BoxDecoration(
                    color: widget.selectedSystem!.colorAsColor.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    '${widget.selectedSystem!.romCount} ROMs',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.surface,
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: widget.selectedSystem != null
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
              : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
          width: 1.r,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12.r,
            offset: Offset(0, 4.r),
          ),
          if (widget.selectedSystem != null)
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              blurRadius: 16.r,
              spreadRadius: 1.r,
            ),
        ],
      ),
      child: widget.selectedSystem == null
          ? _buildEmptyState(context)
          : _buildUnifiedContent(context),
    );
  }

  /// Specialized placeholder state for when no system is targeted.
  Widget _buildEmptyState(BuildContext context) {
    return _buildUnifiedContent(context, isEmptyState: true);
  }

  /// Core rendering engine for the details card, supporting both system-specific
  /// and global branding states.
  Widget _buildUnifiedContent(
    BuildContext context, {
    bool isEmptyState = false,
  }) {
    // UI state resolution based on active selection.
    final isAllSystem =
        isEmptyState ||
        (widget.selectedSystem?.folderName.toLowerCase() == 'all');

    // Dynamic color resolution: primary for the hub, system-specific color otherwise.
    final headerColor = isEmptyState
        ? Theme.of(context).colorScheme.primary
        : (widget.selectedSystem?.colorAsColor ??
              Theme.of(context).colorScheme.primary);

    // Historic launch date metadata.
    final releaseDate = isAllSystem
        ? '30-10-2025'
        : widget.selectedSystem?.launchDate;

    return Padding(
      padding: EdgeInsets.all(12.0.r),
      child: Column(
        children: [
          // Visual Header: Hardware illustration or branding background.
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  headerColor.withValues(alpha: 0.15),
                  headerColor.withValues(alpha: 0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: headerColor.withValues(alpha: 0.3),
                width: 1.r,
              ),
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12.r),
                  child: Image.asset(
                    'assets/images/systems/grid/${isEmptyState ? 'all' : SystemFolderNames.artFolderName(widget.selectedSystem!.folderName)}-detail-background.webp',
                    fit: BoxFit.fill,
                    errorBuilder: (context, error, stackTrace) =>
                        Container(color: headerColor.withValues(alpha: 0.12)),
                  ),
                ),
                if (releaseDate != null)
                  Positioned(
                    bottom: 8.r,
                    left: 8.r,
                    right: 8.r,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 4.r,
                      ),
                      decoration: BoxDecoration(
                        color: headerColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(12.r),
                      ),
                      child: Text(
                        'Released $releaseDate',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 9.h,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          SizedBox(height: 16.r),

          // Main data viewport.
          Expanded(
            child: isEmptyState
                ? _buildNeoStationDescription(context)
                : _buildSystemStats(context),
          ),
        ],
      ),
    );
  }

  /// Placeholder content for the default NeoStation introduction.
  Widget _buildNeoStationDescription(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
          width: 1.r,
        ),
      ),
      child: Text(
        'NeoStation is your ultimate hub for classic games. Relive the nostalgia and rediscover gaming history.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          fontSize: 11.r,
        ),
        maxLines: 7,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }
}
