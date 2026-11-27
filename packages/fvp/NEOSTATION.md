# Vendored fvp 0.40.0

Copy of [fvp 0.40.0](https://pub.dev/packages/fvp/versions/0.40.0) from pub.dev,
kept here for two changes that are not in a released fvp yet:

1. **Native player deletion off the UI isolate** (`lib/src/player.dart`), from
   [wang-bin/fvp#413](https://github.com/wang-bin/fvp/pull/413), fixing
   [wang-bin/fvp#412](https://github.com/wang-bin/fvp/issues/412). On some
   Android devices the hardware decoder never returns from `MediaCodec::stop`,
   and `mdkPlayerAPI_delete` waited for it on the main thread (Flutter runs
   Dart there on Android), freezing the app until Android killed it with an
   ANR. Deletion now runs in `Isolate.run`; if the decoder hangs, that one
   native player is leaked instead of the app freezing.
2. **Pinned MDK SDK on Android** (`android/CMakeLists.txt`): the v0.40.1 release
   archive with its SHA-256, instead of the nightly current at build time.

Other changes from the pub.dev archive: `example/` and `analysis_options.yaml`
removed, `dev_dependencies` dropped, `resolution: workspace` and
`publish_to: none` added.

Drop this copy and go back to the pub.dev package once a fvp release includes
the #413 fix, keeping the MDK pin if fvp still defaults to nightlies.
