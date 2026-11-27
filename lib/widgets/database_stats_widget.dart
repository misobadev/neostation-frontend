import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/sqlite_database_provider.dart';

class DatabaseStatsWidget extends StatelessWidget {
  const DatabaseStatsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SqliteDatabaseProvider>(
      builder: (context, dbProvider, child) {
        if (dbProvider.isLoading) {
          return Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Loading database...'),
                ],
              ),
            ),
          );
        }

        return FutureBuilder<Map<String, dynamic>>(
          future: dbProvider.getStats(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('No database stats available'),
                ),
              );
            }

            final stats = snapshot.data!;

            return Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Database Stats',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 12),
                    _buildStatRow(
                      context,
                      'Systems',
                      stats['totalSystems']?.toString() ?? '0',
                    ),
                    _buildStatRow(
                      context,
                      'Games',
                      stats['totalGames']?.toString() ?? '0',
                    ),
                    _buildStatRow(
                      context,
                      'Favorites',
                      stats['favoriteGames']?.toString() ?? '0',
                    ),
                    _buildStatRow(
                      context,
                      'Played',
                      stats['playedGames']?.toString() ?? '0',
                    ),
                    if (dbProvider.lastUpdate != null) ...[
                      SizedBox(height: 8),
                      Text(
                        'Last updated: ${_formatDateTime(dbProvider.lastUpdate!)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStatRow(BuildContext context, String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hr ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}
