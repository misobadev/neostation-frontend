# Frontend Architecture

This document describes the architecture of the NeoStation Flutter application.

## Overview

NeoStation is a cross-platform Flutter app (Windows, Linux, macOS, Android) that serves as a frontend for retro game emulation. It is landscape-only and does not target web or iOS.

## Layered Architecture

```
┌─────────────────────────────────────────────┐
│  Presentation Layer (UI)                    │
│  lib/screens/  lib/widgets/                 │
├─────────────────────────────────────────────┤
│  State Layer                                │
│  lib/providers/                             │
├─────────────────────────────────────────────┤
│  Business Logic Layer                       │
│  lib/services/                              │
├─────────────────────────────────────────────┤
│  Data Layer                                 │
│  lib/repositories/  lib/data/datasources/   │
├─────────────────────────────────────────────┤
│  External APIs                              │
│  RetroAchievements  ScreenScraper  NeoSync  │
└─────────────────────────────────────────────┘
```

**Dependency rule:** each layer may only depend on the layer immediately below it.

- **Providers** may use **Services** or **Repositories** directly.
- **Services** must use **Repositories** — never talk to `DataSources` directly.
- **Repositories** are the only layer authorized to talk to `DataSources` (SQLite, APIs, files).

### UI Layer

- **`lib/screens/`**: Full pages. `main_screen.dart` is the entry point after launch.
- **`lib/widgets/`**: Reusable UI blocks and atomic shared widgets.

Navigation is handled with standard `Navigator.push/pop` — no GoRouter. Tabs inside `AppScreen` are managed by an index.

### State Layer

- **`lib/providers/`**: `ChangeNotifier` classes consumed via `Provider.of` / `context.read`.

Key providers:
- `SqliteConfigProvider` — main app state (ROM folders, systems, scanning)
- `SqliteDatabaseProvider` — game library data
- `NeoSyncProvider` — cloud save sync state
- `ThemeProvider` — theme switching (14 built-in themes + user custom themes)
- `RetroAchievementsProvider` — RA user data and achievements

### Business Logic Layer

- **`lib/services/`**: External API clients, platform-specific operations, and business logic. **Services do not access SQLite directly.**

Key services:
- `NeoSyncService` — cloud file synchronization
- `SyncManager` (`lib/sync/`) — provider-agnostic save-sync orchestration; cloud backends implement `ISyncProvider` (NeoSync adapter under `lib/sync/providers/`)
- `RetroAchievementsService` — RA API client
- `ScreenScraperService` — metadata scraping with concurrency control
- `GameService` — game launching and session tracking
- `LauncherService` — platform-specific emulator launching
- `LoggerService` — structured logging

### Data Sources

- **`lib/data/datasources/`**: Direct access to SQLite, raw database operations, and migrations.

Data sources:
- `SqliteService` — low-level SQLite database access
- `SqliteDatabaseService` — ROM scanning and game CRUD operations
- `SqliteConfigService` — configuration persistence and system detection
- `sqlite_migrations.dart` — versioned database schema migrations

### Data Layer

- **`lib/repositories/`**: Abstract data access. Repositories are the **only** layer that may call `DataSources`.

Key repositories:
- `ConfigRepository` — user preferences, themes, view modes
- `EmulatorRepository` — emulator paths, cores, standalone emulators
- `GameRepository` — game CRUD, favorites, play time
- `RetroAchievementsRepository` — RA hashes, game IDs, user data
- `ScraperRepository` — scraper config, credentials, metadata persistence
- `SystemRepository` — system detection, settings, extensions
- `SyncRepository` — NeoSync cloud save state tracking or other sync providers

- **SQLite**: Local database for game library, user config, and cached metadata.

Database migrations are versioned in `lib/data/datasources/sqlite_migrations.dart`. Schema changes require updates to **both**:
1. `lib/data/datasources/sqlite_service.dart` — initial `CREATE TABLE` / `_ensure*Columns` for new installs
2. `lib/data/datasources/sqlite_migrations.dart` — idempotent migration in `migrateToVersion` + bump `_databaseVersion`

### External APIs

| API | Purpose | Auth |
|-----|---------|------|
| RetroAchievements | Achievements, leaderboards, game hashes | Per-user web API key (runtime login) |
| ScreenScraper | Game metadata, media, descriptions | `SCREENSCRAPER_DEV_ID/PASSWORD` (build-time) |
| NeoSync Backend | Auth, cloud sync, billing, notifications | JWT (runtime) |

## Platform-Specific Considerations

- **Desktop (Windows/Linux/macOS)**: Uses `window_manager` and `fullscreen_window` for fullscreen toggling. Supports `Alt+Enter` shortcut.
- **Android**: Uses immersive sticky mode, landscape lock, and a custom directory picker for Android TV.
- **Dual-screen handhelds (Android)**: the secondary display runs a second Flutter engine (`subDisplay()` entrypoint in `main.dart`, via the `sub_screen` package) rendering `lib/screens/secondary_screen/`. It is a separate isolate: no shared memory with the main engine — state is shared only through the SQLite database.
- **Gamepad input**: Handled via the local `gamepads` plugin with custom navigation logic in `lib/utils/gamepad_nav.dart`.
- **Home-screen pins (Android)**: NeoStation declares `category.HOME`, so another launcher's "Add to Home Screen" resolves to it. `PinShortcutActivity` (`CONFIRM_PIN_SHORTCUT`) and `ShortcutReceiver` (legacy `INSTALL_SHORTCUT`) queue the request in `PendingShortcuts`; `AndroidShortcutService` drains it into an `android` row whose `rom_path` is a shortcut id and whose `shortcut_intent` holds the launch JSON. Such rows are flagged `is_android_game`, so they list under Android Games, and the Android rescan skips them because they are not installed packages.

## Local Packages (Vendored)

To maintain stability and performance, some libraries are maintained within the `/packages` directory:

- **`gamepads`**: A modified version of Flame Engine's gamepad library, optimized for low-latency UI navigation and multi-controller support.
- **`flutter_7zip`**: FFI bindings for the 7-Zip library. Used for efficient extraction of compressed ROMs (7z, zip, rar) with progress tracking.

## Asset Bootstrap

On first run, SQL files in `assets/data/` initialize database tables.

## Build Configuration

All sensitive values (API keys, backend URLs) are provided at **compile time** via `--dart-define`. There are no runtime `.env` files. See `.env.example` for the list of variables.

## Code Conventions

- Use `Color.withValues(alpha: …)` — not `withOpacity()` (deprecated).
- Guard `BuildContext` use after `await` with `mounted` check.
- Use `flutter_screenutil` for all sizing/spacing.
- Comments and documentation in **English**.
