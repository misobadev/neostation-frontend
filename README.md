<div align="center">

# NeoStation

<h4>Modern, multi-platform emulation frontend built with Flutter</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) [![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FxE2kgKsRVq%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&label=Discord&suffix=%20members&logo=discord&color=5865f2)](https://discord.gg/xE2kgKsRVq) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/miguelsotobaez/neostation-frontend/total) ![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/miguelsotobaez/neostation-frontend/build-and-deploy.yml) [![Stars](https://img.shields.io/github/stars/misobadev/neostation-frontend?logo=github)](https://github.com/misobadev/neostation-frontend) [![Issues](https://img.shields.io/github/issues/misobadev/neostation-frontend)](https://github.com/misobadev/neostation-frontend/issues)  [![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20(x64%2Farm64)%20%7C%20macOS%20%7C%20Android-blue)](https://github.com/misobadev/neostation-frontend)

![NeoStation Hero](https://repository-images.githubusercontent.com/1223168847/4e7a727d-9855-4597-a999-c07167d8552f)

</div>

<div align="left">

NeoStation provides a fast, lightweight, and customizable experience for managing and launching retro games across desktop and mobile devices, with seamless integration for RetroArch and standalone emulators.

---



## Features

- **Modern & customizable UI**: Designed for both large screens and handheld devices, with themes and animations.
- **Collection management**: Intuitively organize your ROMs and platforms.
- **Multi-disc ROM organization**: Automatically create `.m3u` playlists for your multi-disc games and organize them into game folders.
- **RetroArch & standalone emulator integration**: Easy configuration and auto-detection.
- **Multi-platform support**: Windows, Linux, macOS, and Android.
- **Lightweight & fast**: Built with web and native technologies for maximum performance.
- **Advanced configuration**: Deep customization options for power users.
- **Cloud save sync (NeoSync)**: Register, log in, email verification, and profile management.
- **RetroAchievements support**: Track achievements and leaderboard progress.
- **ScreenScraper integration**: Automatic metadata and media scraping.
- **Gamepad & keyboard navigation**: Full controller support across all platforms.
- **12 languages supported**: English, Spanish, Portuguese, Russian, Chinese (Simplified & Traditional), French, German, Italian, Indonesian, Japanese, Korean.

## Multi-disc ROM Organization

The built-in organizer helps prepare multi-disc games for emulators that use `.m3u` playlists:

1. Open **Settings > Tools**.
2. Select **Organize Multi-Disc Games**.
3. NeoStation recursively scans all configured ROM folders and detects disc sets using `Disc`, `Disk`, or `CD` filename markers.
4. Each detected set is placed in a game folder with an `.m3u` playlist. Existing playlists are reused rather than duplicated.

Folders that already contain `.m3u` playlists are skipped during the scan.

## Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| Windows | ✅ Supported | x64 |
| Linux | ✅ Supported | x64, ARM64 (AppImage, Flatpak) |
| macOS | ✅ Supported | Apple Silicon & Intel |
| Android | ✅ Supported | ARM64, Android TV compatible |

## Prerequisites

- Flutter SDK ≥ 3.9.2 — but CI pins an exact version in [`.fvmrc`](.fvmrc), and
  `pubspec.lock` is committed as that version resolves it. Build on the pinned
  version (`fvm use` reads `.fvmrc` directly) or CI will reject your lockfile:
  every job runs `flutter pub get --enforce-lockfile`.
- Dart SDK (bundled with Flutter)
- Git
- RetroArch or standalone emulators

## Installation

### Linux (Flatpak)

```bash
# Coming soon to Flathub! In the meantime, you can build locally:
flatpak-builder --user --install-deps-from=flathub \
  --repo=repo --force-clean \
  build-dir linux/flatpak/com.neogamelab.neostation.yml
```

### Steam Deck

Download the x86_64 AppImage, then **add it to Steam and launch it from there** —
either from Game Mode, or from the desktop with Steam running:

1. Steam → *Games → Add a Non-Steam Game to My Library* → *Browse*
2. Set the file filter to *All Files* (the picker hides `.AppImage` by default)
3. Select the AppImage, then launch NeoStation from your library

This matters for the controls. With Steam not running, the Deck's controller sits
in **lizard mode**, where the hardware emulates a keyboard and mouse instead of a
gamepad: the D-pad sends arrow keys, A/B send Enter/Escape, the trackpad moves the
mouse pointer, and **the bumpers send nothing at all**. Running through Steam hands
the app a proper virtual gamepad, and every button works.

So if the shoulder buttons seem dead, or A/B behave oddly, or a mouse cursor sits on
screen, the app isn't at fault — it's being run outside Steam.

### Build from source

```bash
# Clone the repository
git clone https://github.com/misobadev/neostation-frontend.git
cd neostation-frontend

# Install dependencies
flutter pub get
```

## Build-time Configuration

NeoStation uses compile-time environment variables (`--dart-define`) for Flutter configuration, and Gradle properties for Android signing. No `.env` files are required at runtime.

### Flutter variables (via `--dart-define` or `.env`)

Create a `.env` file from `.env.example` for local development.

| Variable | Description |
|----------|-------------|
| `SCREENSCRAPER_DEV_ID` | ScreenScraper developer ID |
| `SCREENSCRAPER_DEV_PASSWORD` | ScreenScraper developer password |

> RetroAchievements no longer uses a build-time key. Each user signs in with their own RetroAchievements username and web API key (from [retroachievements.org/controlpanel.php](https://retroachievements.org/controlpanel.php)) inside the app.

### Android release signing (optional)

If you want your release APKs signed with a release certificate (required for app store distribution and seamless user upgrades), create `android/key.properties` from `android/key.properties.example`.

```properties
storePassword=your_password
keyPassword=your_password
keyAlias=upload
storeFile=../release.jks
```

If `android/key.properties` is not present, the build automatically falls back to debug signing, which is sufficient for local testing and sideloading.

### GitHub Actions CI/CD

The release workflow (`.github/workflows/build-and-deploy.yml`) reads build secrets from your repository. You can store them as **Environment secrets**.

**Required for all platforms:**

| Secret / Variable | Description |
|-------------------|-------------|
| `SCREENSCRAPER_DEV_ID` | ScreenScraper developer ID |
| `SCREENSCRAPER_DEV_PASSWORD` | ScreenScraper developer password |

**Required for Android release signing:**

| Secret | Description |
|--------|-------------|
| `ANDROID_KEYSTORE_BASE64` | Your `release.jks` file encoded as **base64** (binary, not text). See below. |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Key password |
| `ANDROID_KEY_ALIAS` | Key alias (e.g. `upload`) |

> **Important:** `ANDROID_KEYSTORE_BASE64` must be the **binary keystore file** (`.jks`), not the `key.properties` text file. To encode it:
> ```bash
> # Linux / macOS
> base64 -w 0 release.jks
>
> # Windows PowerShell
> [Convert]::ToBase64String([IO.File]::ReadAllBytes("release.jks"))
> ```

If the Android secrets are missing, the CI build falls back to debug signing (users will need to uninstall before installing a new release).

### Running

```bash
# Development
flutter run \
  --dart-define=SCREENSCRAPER_DEV_ID=your_id \
  --dart-define=SCREENSCRAPER_DEV_PASSWORD=your_password

# Production builds
# Replace these with your actual keys
DART_DEFINES="--dart-define=SCREENSCRAPER_DEV_ID=your_id --dart-define=SCREENSCRAPER_DEV_PASSWORD=your_password"

# Android APK
flutter build apk --release $DART_DEFINES

# Windows
flutter build windows --release $DART_DEFINES

# Linux
flutter build linux --release $DART_DEFINES

# macOS
flutter build macos --release $DART_DEFINES
```

## Project Structure

```
lib/
├── data/
│   └── datasources/     # SQLite access, migrations, raw queries
├── l10n/               # Localization files (12 languages)
├── models/             # Data models
├── providers/          # ChangeNotifier state management
├── repositories/       # Data access abstraction layer
├── screens/            # Application pages
├── services/           # Business logic and external APIs
├── sync/               # Provider-agnostic cloud sync (SyncManager + adapters)
├── themes/             # App themes
├── utils/              # Helpers and utilities
├── widgets/            # Reusable UI components
├── main.dart           # Entry point
```

For more details, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Local Packages

### Third-Party Licenses & Credits
NeoStation is built upon the incredible work of the open-source community. To achieve the specific performance and compatibility goals of this project, we utilize modified versions of several libraries.

These packages are "vendored" within the /packages directory to ensure long-term stability and to include custom optimizations:

| Package | Description |
|---------|-------------|
| `gamepads` | Cross-platform gamepad input (based on Flame Engine's gamepads) |
| `flutter_7zip` | FFI bindings for 7-Zip archive extraction |

## Systems & Emulator Definitions

NeoStation's system configurations, emulator definitions, and launch arguments are maintained in this repository under [`assets/systems/`](assets/systems/).  
**If you want to add new emulators, fix launch arguments, or update system configurations, please open a pull request here.**

The bundled `assets/manifest.json` drives the over-the-air systems update mechanism, so compatible changes can be delivered to existing installs without requiring a full app release.

## Contributing

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines on bug reports, feature requests, and pull requests.

## Security

If you discover a security vulnerability, please follow the instructions in [`SECURITY.md`](SECURITY.md) to report it responsibly.

## Project Team

### Lead

- **@misobadev**

### Official Co-Maintainers

- **@androosio**

### Official Community Manager

- **@ItsRetroPup**
  - Ko-fi: https://ko-fi.com/retropup84752

These co-maintainers and collaborators work very hard to make NeoStation what it is today.

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [`LICENSE.md`](LICENSE.md) for details.

Third-party components and assets have their own licenses — see [`NOTICE`](NOTICE.md).

### Desktop shortcut games

Create a `pc` folder inside a configured ROM root, place game shortcuts in it,
and rescan to see **PC Games**. No emulator configuration is required.

- Windows: `.lnk` and `.url` (including store links).
- macOS: Finder aliases and `.webloc` files.
- Linux: `.desktop` files; `gio` must be installed on the host.

Only the current OS's formats are recognised. Existing recursive and hidden-file
scan settings apply. Shortcuts retain their original paths and launch through the
OS, preserving their launch arguments and store associations. Playtime ends when
you return to NeoStation after it loses focus; dismiss the launch dialog manually
if a shortcut does not transfer focus. A successful handoff to a store client does
not guarantee that the client subsequently starts the game.
