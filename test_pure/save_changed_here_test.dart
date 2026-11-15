import 'package:neostation/utils/save_changed_here.dart';
import 'package:test/test.dart';

/// Whether a save changed on this device since its last sync decides both a
/// game's sync and whether a newer cloud copy keeps this device's save as its
/// own copy (NEO-243): one rule for both.
void main() {
  bool changed({
    int localTime = 100000,
    String localHash = 'now',
    int? savedTime = 50000,
    String? savedHash = 'then',
  }) => saveChangedHere(
    localTime: localTime,
    localHash: localHash,
    savedTime: savedTime,
    savedHash: savedHash,
  );

  test('never synced: changed, as nothing can be ruled out', () {
    expect(changed(savedTime: null, savedHash: null), isTrue);
  });

  test('its time moved and its content differs: changed', () {
    expect(changed(), isTrue);
  });

  test('its time moved but its content is the same: not changed', () {
    expect(changed(savedHash: 'now'), isFalse);
  });

  test('its time didn\'t move: not changed, whatever hash was recorded', () {
    expect(changed(savedTime: 100000), isFalse);
    expect(changed(savedTime: 98000), isFalse, reason: 'within 2 s');
    expect(changed(savedTime: 100000, savedHash: null), isFalse);
  });

  test('its time moved and no hash was recorded: changed', () {
    expect(changed(savedHash: null), isTrue);
    expect(changed(savedHash: ''), isTrue);
  });

  test('just past the 2 s tolerance, either way', () {
    expect(changed(savedTime: 97999), isTrue);
    expect(changed(savedTime: 102001), isTrue);
  });
}
