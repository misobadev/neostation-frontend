import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/playtime_meter.dart';

void main() {
  late Duration now;
  late PlaytimeMeter meter;

  void advance(Duration d) => now += d;

  setUp(() {
    now = Duration.zero;
    meter = PlaytimeMeter(clock: () => now);
  });

  test('counts time while running', () {
    meter.start();
    advance(const Duration(minutes: 30));
    expect(meter.elapsed, const Duration(minutes: 30));
  });

  test('a screen-off pause leaves the sleep out of the total', () {
    meter.start();
    advance(const Duration(minutes: 30));
    meter.pause();
    advance(const Duration(hours: 20)); // asleep overnight
    meter.resume();
    advance(const Duration(hours: 3));
    expect(meter.elapsed, const Duration(hours: 3, minutes: 30));
  });

  test('pause and resume are idempotent', () {
    meter.start();
    advance(const Duration(seconds: 10));
    meter.pause();
    meter.pause();
    advance(const Duration(seconds: 50));
    meter.resume();
    advance(const Duration(seconds: 5));
    meter.resume(); // must not restart the segment
    advance(const Duration(seconds: 5));
    expect(meter.elapsed, const Duration(seconds: 20));
  });

  test('start(paused: true) counts nothing until resumed', () {
    meter.start(paused: true);
    advance(const Duration(minutes: 5));
    expect(meter.elapsed, Duration.zero);
    meter.resume();
    advance(const Duration(minutes: 1));
    expect(meter.elapsed, const Duration(minutes: 1));
  });

  test('takeUnreported hands out each second once', () {
    meter.start();
    advance(const Duration(seconds: 10));
    expect(meter.takeUnreported(), 10);
    expect(meter.takeUnreported(), 0);
    advance(const Duration(seconds: 4));
    meter.pause();
    advance(const Duration(hours: 8));
    expect(meter.takeUnreported(), 4);
  });

  test('start resets a previous session', () {
    meter.start();
    advance(const Duration(minutes: 10));
    meter.takeUnreported();
    meter.start();
    advance(const Duration(seconds: 3));
    expect(meter.elapsed, const Duration(seconds: 3));
    expect(meter.takeUnreported(), 3);
  });
}
