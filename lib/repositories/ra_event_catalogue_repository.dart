import 'dart:convert';
import 'package:flutter/services.dart';

class RaEventCatalogueRepository {
  /// No guessed calendar after rollover: a missing year needs a catalogue update.
  static Future<Map<String, dynamic>> load(int year) async =>
      Map<String, dynamic>.from(
        jsonDecode(
              await rootBundle.loadString('assets/data/ra_events_$year.json'),
            )
            as Map,
      );
}
