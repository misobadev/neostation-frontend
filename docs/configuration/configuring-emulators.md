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

## Related Pages

- [Getting Started](/getting-started/getting-started/)
- [Troubleshooting](/troubleshooting/)
