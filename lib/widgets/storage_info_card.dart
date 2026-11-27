import 'package:flutter/material.dart';

class StorageInfoCard extends StatelessWidget {
  const StorageInfoCard({
    super.key,
    required this.title,
    required this.svgSrc,
    required this.amountOfFiles,
    required this.numOfFiles,
  });

  final String title, svgSrc, amountOfFiles;
  final int numOfFiles;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.only(top: 6.0), // defaultPadding = 16.0
      child: Padding(
        padding: EdgeInsets.all(16.0), // defaultPadding = 16.0
        child: Row(
          children: [
            SizedBox(height: 20, width: 20),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16.0,
                ), // defaultPadding = 16.0
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium, // Usar tema
                    ),
                    Text(
                      "$numOfFiles Files",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.7),
                      ), // Usar tema con transparencia
                    ),
                  ],
                ),
              ),
            ),
            Text(
              amountOfFiles,
              style: Theme.of(context).textTheme.bodyMedium, // Usar tema
            ),
          ],
        ),
      ),
    );
  }
}
