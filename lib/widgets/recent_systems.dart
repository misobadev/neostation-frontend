import 'package:neostation/models/recent_file.dart';

import 'package:flutter/material.dart';

class RecentSystems extends StatelessWidget {
  const RecentSystems({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context)
          .colorScheme
          .surface, // Now surface = secondaryColor
      elevation: Theme.of(context).cardTheme.elevation ?? 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(16.0), // Replaces defaultPadding
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Recent Systems",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16.0), // Replaces defaultPadding
            Theme(
              data: Theme.of(context).copyWith(
                scaffoldBackgroundColor: Theme.of(context).colorScheme.surface,
                dividerTheme: DividerThemeData(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.1), // More transparent divider
                  thickness: 0.5, // Thinner lines
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: DataTable(
                  columnSpacing: 16.0, // Replaces defaultPadding
                  dividerThickness: 0.5, // Thinner lines
                  showBottomBorder: false, // No bottom border
                  columns: [
                    DataColumn(label: Text("File Name")),
                    DataColumn(label: Text("Date")),
                    DataColumn(label: Text("Size")),
                  ],
                  rows: List.generate(
                    demoRecentSystems.length,
                    (index) =>
                        recentFileDataRow(demoRecentSystems[index], context),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

DataRow recentFileDataRow(RecentFile fileInfo, BuildContext context) {
  return DataRow(
    cells: [
      DataCell(
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
              ), // Replaces defaultPadding
              child: Text(
                fileInfo.title!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
      DataCell(
        Text(
          fileInfo.date!,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.7),
          ),
        ),
      ),
      DataCell(
        Text(
          fileInfo.size!,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.7),
          ),
        ),
      ),
    ],
  );
}
