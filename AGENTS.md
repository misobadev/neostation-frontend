# AGENTS.md

This file provides guidance to coding agents (including Claude Code, which reads `AGENTS.md`) when working with code in this repository.

NeoStation is a landscape-only, gamepad-driven Flutter emulation frontend for **Windows, Linux, macOS, and Android** (no web, no iOS). Two existing docs are authoritative and worth reading before non-trivial work:
- `ARCHITECTURE.md` — layered architecture, providers/services/repositories/datasources, code conventions.
- `README.md` — build-time configuration (`--dart-define`), Android signing, CI secrets, vendored packages.

This file captures the commands and the cross-cutting rules that aren't obvious from any single file.

Personal, machine-specific notes belong in an untracked `AGENTS.local.md` (already gitignored via `*.local.md`).

## Commands

```bash
flutter pub get
flutter analyze                 # must be clean (no errors/warnings) — CI enforces it
dart format .                   # CI fails on unformatted code (--set-exit-if-changed)
flutter test                    # all tests — CI enforces it
flutter test test/game_service_test.dart                       # a single test file
flutter test test/game_service_test.dart --plain-name "name"   # tests matching a name
```

CI (`.github/workflows/build-and-deploy.yml`) runs format check + analyze + test before the platform build matrix.

Run/build need build-time secrets via `--dart-define` (`SCREENSCRAPER_DEV_ID`, `SCREENSCRAPER_DEV_PASSWORD`) — without them, ScreenScraper features degrade but the app still runs. RetroAchievements has no build-time key: each user signs in with their own web API key at runtime. See README for the full matrix.

```bash
flutter run   --dart-define=SCREENSCRAPER_DEV_ID=... --dart-define=SCREENSCRAPER_DEV_PASSWORD=...
flutter build apk --release   <same --dart-define flags>
```

Android release builds go through `build-utils/build-android.sh` (or `build-android.ps1` on Windows). They pass `--android-project-arg=force-version-code-ignoring-abi=true` so the per-ABI APKs keep the pubspec build number as `versionCode`, matching local `flutter run` installs instead of tripping Android's downgrade check. Do not remove that flag without first raising the pubspec build number above the codes already shipped.

There is no release-keystore requirement for local work: if `android/key.properties` is absent, the Android build falls back to debug signing automatically.

**Test speed.** Never burn real wall-clock time to clear `GamepadNavigation`'s activation grace or key throttle. Use `test/gamepad_test_clock.dart` (`resetGamepadClock`, `advanceGamepadClock`) so the navigator's injected clock moves forward instantly. Keep `runAsync` for real I/O only. Network/slow suites are tagged (`@Tags(['network'])`): `flutter test --exclude-tags network` gives fast local feedback. CI splits the test files across four shards manually (`-j 4`), and `dart tool/test_slowest.dart test-results.json` prints the slowest suites from the JSON reporter output.

**Pure Dart tests.** Logic that does not touch Flutter lives in `test_pure/` and runs with `dart test test_pure` (no Flutter engine). Those files import `package:test/test.dart`, not `flutter_test`; `flutter test` only discovers `test/`. On Linux the app package's build hooks still compile `cnativeapi`, so the pure job installs the same GTK/X11/Xi packages; a separate pure package is the next step to remove that dependency. Use `dart tool/classify_pure_tests.dart` to find new candidates.

**Plugin channels in widget tests.** Use `test/support/plugin_channel_mocks.dart` (`installDefaultPluginMocks`) for benign plugin defaults instead of repeating `setMockMethodCallHandler`; override a channel in the test when its behaviour matters.

## Cross-cutting rules (read multiple files to get right)

**Layer dependency direction is strict** (see ARCHITECTURE.md): UI → providers → services → repositories → datasources. Services must NOT touch `lib/data/datasources/` directly — go through a repository. Repositories are the only layer allowed to call `SqliteService`/datasources. Cloud-save sync goes through the provider-agnostic `lib/sync/` layer (`SyncManager` + `ISyncProvider`), with NeoSync as the adapter under `sync/providers/`.

**Database schema changes:** new columns go in a **versioned migration**, never the on-launch `_ensure*Columns` ALTER pattern (maintainer's rule, PR #57), and the downgrade path **recreates the database** — a lower-`_databaseVersion` build over a newer DB wipes local data. Never assume a numbered migration ran; guard new columns and ship idempotent backfills. Full rules — version-collision merges across branches, threading a `user_system_settings` column through every system-loading query, and the migration-test pattern — are in `lib/data/datasources/CLAUDE.md`, which loads when you work in that directory.

**Dual-display devices run a second Flutter engine.** `subDisplay()` in `lib/main.dart` (tagged `@pragma('vm:entry-point')`, driven by the `sub_screen` package) renders `lib/screens/secondary_screen/` on dual-screen Android handhelds. It is a separate engine/isolate: it initializes localization and config independently and shares **nothing in memory** with the main engine — both open the same SQLite database. Any state that must appear on both screens has to be persisted or re-derived, not assumed shared. The BACK-key teardown of `SecondaryAppsPresentation` (a `Dialog`, so cancelable and focusable by default), the restore race behind a dock-launched app, and their repro conditions are in `android/CLAUDE.md`.

**Android ROM paths are SAF content URIs, not filesystem paths.** `GameModel.romPath` on Android looks like `content://…/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip` (separators URL-encoded as `%2F`). Desktop uses plain paths. Any path parsing (subfolder/directory logic) must handle the URL-encoded SAF form. **Test path logic on a device, not just desktop** — unit tests use plain paths and won't catch this.

**Localization is custom and map-based** (the `flutter_localization` package, not gen-l10n/ARB). Adding a string requires: a `static const String` key in `lib/l10n/app_locale.dart`, then a value in **every** `lib/l10n/app_locale_<lang>.dart` file (12 languages: de, en, es, fr, id, it, ja, ko, pt, ru, zh, zh_hant). A missing key in any file is an analyzer error.

**Every user-facing string goes through `AppLocale` — no hardcoded UI text.** This applies to every screen including NeoSync (dashboard, save list, custom folders, plan view, dialogs). Filter/menu labels, hints, buttons, empty states, and interpolated strings must all be localized: define the key + the 12 translations, then use `AppLocale.<key>.getString(context)` (and `.replaceFirst('{placeholder}', value)` for interpolation). Strings with parameters keep the `{name}` placeholder form. Log messages (`_log.*`) and internal-only strings are exempt. The analyzer does not enforce this — grep for `Text('...')`, `label: '...'`, `hintText: '...'`, `title: '...'`, and `subtitle: '...'` with capitalized/long literals to catch leaks (the `lib/screens/neo_sync_screen/` directory is a known hotspot).

**Gamepad navigation is custom** (`lib/utils/gamepad_nav.dart` + `GamepadNavigationManager` layer stack). Screens own their selection index and drive child views via `selectedIndex`; the list/grid/carousel widgets are largely presentational. Every interactive element must be reachable by D-pad/controller, not just touch/mouse; B is the app-wide back/cancel action, including escaping a focused text field. Injected Android `adb input keyevent` D-pad events are NOT picked up by this nav (use `input tap` when scripting the UI).

**Every full-screen route must register a `GamepadNavigationManager` layer** — not just call `_gamepadNav.activate()`. On resume, `GameLaunchService.handleAppResumed()` calls `GamepadNavigationManager.reactivate()`, which wakes the top *registered* layer. A screen that activated its navigator without pushing a layer is invisible to the manager, so returning from a launched app/emulator wakes the screen buried underneath it and two navigators then handle the same button press. That is how the Android apps grid came to launch several apps at once: it launched the focused app while the systems carousel behind it re-entered the system and stacked a second copy of the grid, so each further press launched one more app the user never selected. Push the layer in the same post-frame callback as `initialize()`, and `popLayer` in `dispose()`.

**Android keycode buttons arrive action-encoded and inverted.** On Android (confirmed on the AYN Thor) the gamepads plugin reports keycode-backed buttons with press = `0.0` and release = `1.0` — the opposite of the analog convention. The translator historically un-inverted only the D-pad, so face/shoulder buttons fired on *release* and held modifiers (Select, L1/R1) latched stuck. When adding a button binding, check how that button's value is decoded before assuming `> 0.5` means pressed; press/release edges for modifier keys are read at the raw key level.

**System/emulator definitions live in this repo.** `assets/systems/*.json` is the single source of truth for systems, emulator definitions, and launch arguments — PRs for emulator fixes belong here (the separate `neostation-systems` repo is defunct). The bundled `assets/manifest.json` drives the over-the-air systems update mechanism, so compatible changes reach existing installs without an app release. `assets/data/` SQL files seed the database on first run.

**Prefer JSON over Kotlin for emulator launch fixes (maintainer's architectural rule).** Keep `EmulatorLauncher.kt` emulator-agnostic — do **not** add new conditionals / hardcoded package lists there unless strictly necessary. First try to fix launch behaviour by editing the emulator's `launch_arguments` in its `assets/systems/<sys>.json` — usually swapping the path placeholder is enough:
- `{file.path}` → best-effort real filesystem path (resolves SAF `content://` to a raw path; for emulators that need a real path).
- `{file.localuri}` → keeps a `content://` SAF URI as-is (so `launchGenericIntent` can grant it read permission); falls back to `file://` for bare paths.
- `{file.uri}` → `content://`/`file://` pass through; bare paths → `file://`.
The opt-out from our FileProvider rewrap (for emulators that need the original SAF `content://` URI — e.g. Flycast's `.zip` loading, DraStic) is **config-driven**, not a hardcoded Kotlin package list: set `"keep_saf_uri": true` in the emulator's `android` block in `assets/systems/<sys>.json`. The flag threads through `LauncherService` → `game_service.dart` (method channel) → `EmulatorLauncher.kt`, which keeps the Kotlin emulator-agnostic. Example: issue #50/#66 (DraStic) was fixed by `{file.path}`→`{file.localuri}` **plus** `"keep_saf_uri": true` — no Kotlin change. Likewise `"m3u_first_disc": true` boots a multi-disc `.m3u` on its first disc, for emulators that can't open a playlist over SAF (Android Dolphin, the PCSX2 family; issue #605); `LauncherService.resolveAndroidLaunchFiles` applies it. Only touch `EmulatorLauncher.kt` if a genuinely new mechanism (not just another opt-out emulator) is needed.

**Testing embedded `assets/systems/` changes locally:** the app prefers previously downloaded systems over the bundle unless the bundle's version is higher. To force it to read your local edits, bump `latest_version` in `assets/manifest.json` above whatever value is currently there; on launch you'll see `SystemsUpdateService: bundled vX > cached "Y", clearing cache`.

**Vendored packages** live in `/packages/` (`gamepads*`, `flutter_7zip`, `sub_screen`) — modified upstream libraries wired in as a pub workspace; prefer fixing there over working around them. `sub_screen` is vendored because its upstream repository is gone; keep its `FlutterPresentation.flutterEngine` field name in sync with the reflection in `SecondaryAppsPresentation.kt`.

## Conventions

Beyond standard Dart/Flutter (and the items in ARCHITECTURE.md — `Color.withValues(alpha:)` not `withOpacity`, `mounted` guards after `await`, `flutter_screenutil` for all sizing, English comments): widgets `PascalCase`, variables `camelCase`, files `snake_case`. Conventional Commits (`feat:`, `fix:`, …); branches `feature/…`, `fix/…`, `refactor/…`, `docs/…`; PRs use `.github/PULL_REQUEST_TEMPLATE.md`. All user-facing UI text goes through `AppLocale` — never hardcoded strings.

**Never silence analyzer or linter findings.** Do not add `// ignore:`, `// ignore_for_file:`, `// ignore_for_file: deprecated_member_use`, analyzer `errors:` overrides, or any other suppression to make `flutter analyze` pass. Fix the root cause: migrate the code to the API the finding points at (for a dependency bump, use its documented migration path or its replacement API), or pin/change the dependency if the new version cannot be adopted yet. Suppressing the diagnostic hides real problems and is not an acceptable fix.

## Commits (per AI_GUIDELINES.md)

- **Never** add a DCO sign-off from an AI (no `git commit -s` / `Signed-off-by:`).
- For significant AI-assisted work, add an `AI-Assisted: NAME:VERSION` trailer (e.g. `AI-Assisted: Claude:Fable-5`). A `Co-Authored-By:` trailer is fine and used in practice.
- Code must pass `dart format`, `flutter analyze` (clean), and `flutter test` (all passing) before commit — CI enforces all three.
