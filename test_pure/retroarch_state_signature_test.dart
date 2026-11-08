import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:neostation/sync/retroarch_state_signature.dart';

/// The two fixtures are real save states captured from the test rig on
/// 2026-08-09 — the same pair that proved the data-loss bug: an FCEUmm state
/// written on an AYN Thor and a Mesen state written on a Steam Deck, for one
/// game, both RZIP-compressed by RetroArch.
Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  late Uint8List fceumm;
  late Uint8List mesen;

  setUpAll(() {
    fceumm = _fixture('fceumm_sample.state');
    mesen = _fixture('mesen_sample.state');
  });

  group('RetroArchStateSignature.of', () {
    test('reads the core magic out of a real RZIP-compressed FCEUmm state', () {
      // 'FCS' — FCEU's own save-state magic, inside RASTATE's MEM block.
      expect(RetroArchStateSignature.of(fceumm), isNotNull);
      expect(
        String.fromCharCodes(RetroArchStateSignature.of(fceumm)!.take(3)),
        'FCS',
      );
    });

    test('reads the core magic out of a real Mesen state', () {
      expect(
        String.fromCharCodes(RetroArchStateSignature.of(mesen)!.take(3)),
        'MST',
      );
    });

    test('two cores produce different signatures', () {
      expect(
        RetroArchStateSignature.of(fceumm),
        isNot(equals(RetroArchStateSignature.of(mesen))),
      );
    });

    test('has no opinion on bytes that are not a save state', () {
      expect(
        RetroArchStateSignature.of(utf8Bytes('not a state at all')),
        isNull,
      );
    });

    test('has no opinion on an empty file', () {
      expect(RetroArchStateSignature.of(Uint8List(0)), isNull);
    });

    test('has no opinion on a truncated RZIP header', () {
      expect(RetroArchStateSignature.of(fceumm.sublist(0, 12)), isNull);
    });

    test('has no opinion on RZIP framing wrapped around garbage', () {
      final bogus = Uint8List.fromList([
        ...fceumm.sublist(0, 24), // valid-looking RZIP header
        ...List.filled(64, 0xAB), // not a zlib stream
      ]);
      expect(RetroArchStateSignature.of(bogus), isNull);
    });

    test('reads an uncompressed RASTATE container too', () {
      // savestate_compression off: the container is not RZIP-wrapped.
      final raw = Uint8List.fromList([
        ...'RASTATE'.codeUnits,
        1,
        ...'MEM '.codeUnits,
        8,
        0,
        0,
        0,
        ...'FCS\xff'.codeUnits,
        0,
        0,
        0,
        0,
      ]);
      expect(
        String.fromCharCodes(RetroArchStateSignature.of(raw)!.take(3)),
        'FCS',
      );
    });
  });

  group('RetroArchStateSignature.differ', () {
    test('is true for two different cores — this is the guard that fires', () {
      expect(RetroArchStateSignature.differ(fceumm, mesen), isTrue);
    });

    test('is false for the same state compared with itself', () {
      expect(RetroArchStateSignature.differ(fceumm, fceumm), isFalse);
    });

    test('is false when either side is unidentifiable', () {
      // The load-bearing property: an unrecognised state must never block a
      // transfer that works today. Cores with no magic, standalone emulators'
      // own formats, and future container changes all land here.
      final junk = utf8Bytes('some other emulator format');
      expect(RetroArchStateSignature.differ(fceumm, junk), isFalse);
      expect(RetroArchStateSignature.differ(junk, mesen), isFalse);
      expect(RetroArchStateSignature.differ(junk, junk), isFalse);
    });

    test('is false when either side is null', () {
      expect(RetroArchStateSignature.differ(null, mesen), isFalse);
      expect(RetroArchStateSignature.differ(fceumm, null), isFalse);
    });
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);
