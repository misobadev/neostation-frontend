import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_save_game.dart';
import 'package:neostation/screens/saves_screen/romm_save_artwork.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/themes/corner_radii.dart';

/// A 1x1 PNG, so a found cover decodes into a real frame.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

class _ArtworkService extends RommService {
  final calls = <String>[];
  final failed = <String>{};
  @override
  Future<RommImageFetch> fetchImage(
    String url, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    calls.add(url);
    if (failed.contains(url)) {
      return const RommImageFetch.missing(RommImageMiss.absent);
    }
    return RommImageFetch.found(_pixel);
  }
}

void main() {
  testWidgets('a missing thumbnail falls back to the next stored cover', (
    tester,
  ) async {
    final service = _ArtworkService()
      ..failed.add('https://romm.test/small.png');
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, child) => MaterialApp(
          theme: ThemeData(extensions: [CornerRadii.m()]),
          home: Scaffold(
            body: RommSaveArtwork(
              width: 60,
              height: 80,
              service: service,
              info: const RommSaveGameInfo(
                serverCovers: [
                  'https://romm.test/small.png',
                  'https://romm.test/large.png',
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    expect(service.calls, [
      'https://romm.test/small.png',
      'https://romm.test/large.png',
    ]);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
