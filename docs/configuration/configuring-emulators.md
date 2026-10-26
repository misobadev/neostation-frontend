---
title: Configuring Emulators
layout: default
nav_order: 3
---

# Configuring Emulators

NeoStation uses the bundled system definitions to decide which emulators are available for each system. Available choices depend on your platform and installed software.

## RetroArch

If you use RetroArch, configure it as the emulator for a system and make sure the required core is installed. When a launch fails, NeoStation can report that RetroArch, its executable, core directory, or selected core is missing.

## Standalone Emulators

On desktop platforms, NeoStation can ask you to select the executable for a standalone emulator.

1. Open **Settings → Emulators**.
2. Open **Standalone Emulators**.
3. Select a system, then the emulator you want to configure.
4. Select its executable:
   - Windows: choose the emulator's `.exe` file.
   - Linux: use the executable picker.
   - macOS: choose the emulator executable.

NeoStation stores the selected path for that emulator. Repeat this for each standalone emulator you use.

Configuring the emulator's executable is separate from cloud saves. Standalone emulators store their saves in their own folders, so to sync those saves you must also point NeoStation at each save folder in **NeoSync → Custom Save Folders**. See [NeoSync](/features/neosync/#custom-save-folders).

## Android

Android launches supported standalone emulators using their configured application integration. There is no desktop executable-picker step on Android.

## PS3 packages, folders and shortcuts

PS3 libraries can contain several formats. NeoStation recognises them as a
single game each instead of exposing internal files:

```text
roms/ps3/
  Disc Game.ps3/
    PS3_GAME/
      PARAM.SFO
      USRDIR/EBOOT.BIN
  NPEB00913.ps3/
    PARAM.SFO
    USRDIR/EBOOT.BIN
    TROPDIR/
  Game.pkg
  Game.ps3          # serial descriptor, not a folder
```

The `.ps3` suffix is optional for directories. A disc folder contains
`PS3_GAME/PARAM.SFO`; an extracted PSN folder contains `PARAM.SFO` and
`USRDIR/EBOOT.BIN` directly. The folder is passed to the emulator as a
directory, so aPS3e uses its `game_dir` intent instead of its ISO intent.
RPCS3 receives the folder path on desktop. Firmware, PSN installation
requirements and licenses remain the emulator's responsibility; scanning does
not install a PKG.

A `.pkg` file is passed as a package path on Android. A small `.ps3` text file
containing a title serial (for example `NPEB00913`) is read and passed as a
`title_id` to the matching ARMSX3 entry. Shortcuts (`.lnk` on Windows,
`.desktop` on Linux) are resolved to their target executable so the game
session is tracked correctly. A shortcut that cannot be resolved fails with an
explicit error instead of launching a detached shell process.

## Native ports

The **Native Ports** system is available on desktop platforms and is hidden on
Android. Add the port's executable (`.exe`, AppImage, `.sh`, or a bare
`x86_64`/`aarch64` binary), `.lnk`, `.desktop`, or `.app` bundle to a `ports`
folder and scan the system. NeoStation starts the executable directly from its
own directory, which is required by ports such as Dusklight that load assets
relative to the working directory.

## Related Pages

- [Getting Started](/getting-started/getting-started/)
- [Troubleshooting](/troubleshooting/)
