<div align="center">

# NeoStation

<h4>Modern, multi-platform emulation frontend built with Flutter</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) [![Discord](https://img.shields.io/discord/1088818368129273946?label=Discord&logo=discord&color=5865f2)](https://discord.gg/xE2kgKsRVq) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/misobadev/neostation-frontend/total) ![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/misobadev/neostation-frontend/build-and-deploy.yml)

![NeoStation Hero](https://repository-images.githubusercontent.com/1223168847/145cb04c-3479-4eb5-bbb6-23d14d047a7c)

</div>

<div align="left">

NeoStation provides a fast, lightweight, and customizable experience for managing and launching retro games across desktop and mobile devices, with seamless integration for RetroArch and standalone emulators.

---



## Features

- **Modern & customizable UI**: Designed for both large screens and handheld devices, with themes and animations.
- **Collection management**: Intuitively organize your ROMs and platforms.
- **RetroArch & standalone emulator integration**: Easy configuration and auto-detection.
- **Multi-platform support**: Windows, Linux, macOS, and Android.
- **Lightweight & fast**: Built with web and native technologies for maximum performance.
- **Advanced configuration**: Deep customization options for power users.
- **Cloud save sync (NeoSync)**: Register, log in, email verification, and profile management.
- **RetroAchievements support**: Track achievements and leaderboard progress.
- **ScreenScraper integration**: Automatic metadata and media scraping.
- **Gamepad & keyboard navigation**: Full controller support across all platforms.
- **10 languages supported**: English, Spanish, Portuguese, Russian, Chinese, French, German, Italian, Indonesian, Japanese.

## Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| Windows | ✅ Supported | x64 |
| Linux | ✅ Supported | x64, ARM64 (AppImage, Flatpak) |
| macOS | ✅ Supported | Apple Silicon & Intel |
| Android | ✅ Supported | ARM64, Android TV compatible |

## Prerequisites

- Flutter SDK ≥ 3.9.2
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
| `RA_API_KEY` | RetroAchievements API key — get yours at [retroachievements.org/controlpanel.php](https://retroachievements.org/controlpanel.php) |
| `SCREENSCRAPER_DEV_ID` | ScreenScraper developer ID |
| `SCREENSCRAPER_DEV_PASSWORD` | ScreenScraper developer password |

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
| `RA_API_KEY` | RetroAchievements API key |
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
  --dart-define=RA_API_KEY=your_key \
  --dart-define=SCREENSCRAPER_DEV_ID=your_id \
  --dart-define=SCREENSCRAPER_DEV_PASSWORD=your_password

# Production builds
# Replace these with your actual keys
DART_DEFINES="--dart-define=RA_API_KEY=your_key --dart-define=SCREENSCRAPER_DEV_ID=your_id --dart-define=SCREENSCRAPER_DEV_PASSWORD=your_password"

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
├── l10n/               # Localization files (10 languages)
├── models/             # Data models
├── providers/          # ChangeNotifier state management
├── repositories/       # Data access abstraction layer
├── screens/            # Application pages
├── services/           # Business logic and external APIs
├── themes/             # App themes and palettes
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
| `flutter_soloud` | Low-level audio playback using the SoLoud engine |

## Systems & Emulator Definitions

NeoStation's system configurations, emulator definitions, and launch arguments are maintained in a separate repository.  
**If you want to add new emulators, fix launch arguments, or update system configurations, please open a pull request in the dedicated systems repository:**

👉 [**misobadev/neostation-systems**](https://github.com/misobadev/neostation-systems)

Changes to these files are not accepted in this frontend repository.

## Contributing

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines on bug reports, feature requests, and pull requests.

## Security

If you discover a security vulnerability, please follow the instructions in [`SECURITY.md`](SECURITY.md) to report it responsibly.

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [`LICENSE.md`](LICENSE.md) for details.

Third-party components and assets have their own licenses — see [`NOTICE`](NOTICE.md).
