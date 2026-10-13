---
title: NeoSync
layout: default
parent: Features
nav_order: 3
---

# NeoSync

NeoSync is your cloud companion for NeoStation. It keeps your game saves, save states and memory cards in sync across all of your devices, so your progress is safe even if a device is lost or replaced.

## Before You Start

The **Saves** tab is hidden by default. To show it:

1. Open **Settings → General**.
2. Turn on **Show Saves tab**.

The tab uses NeoSync by default. When **Use RomM for save sync** is enabled
in the RomM tab, Saves instead shows your RomM saves and save states. Turn
that option off to return to NeoSync, including its account and plan controls.

## The Official Site

The official NeoSync website is [https://neosync.cloud/](https://neosync.cloud/). You can sign in or create an account there exactly as you can in the NeoStation app.

## Sign In or Create an Account

Open the **Saves** tab and choose to create an account or sign in. You can also do this on the [official site](https://neosync.cloud/).

- New accounts need email verification. NeoStation can resend the verification email.
- If you forget your password, use the password recovery option.

## How NeoStation Finds Your Saves

NeoStation supports two kinds of emulators, and it locates each one differently:

- **RetroArch and its libretro cores.** NeoStation reads your RetroArch configuration and syncs the folders you set there for saves and save states. The core that wrote a save is detected automatically, so the same save stays linked to the right core on every device. No setup is needed beyond having RetroArch configured.
- **Standalone emulators** (Eden, Citron, Yuzu, DuckStation, ARMSX2, Flycast, PPSSPP and so on). These keep their saves in their own folders, which NeoStation cannot locate reliably on its own. For every standalone emulator you use, you must point NeoStation at its save folder once, per system and emulator, using **Custom Save Folders**. A standalone emulator without a configured folder is **not synced**.

Every upload goes to the NeoSync v2 storage, and each file is stored together with the system and the emulator that produced it, so it is always placed back with the correct emulator on every device. Old NeoSync v1 saves are no longer uploaded or downloaded; only v2 is used.

## How Automatic Syncing Works

NeoStation syncs automatically, but it does **not** sync all of your saves at once — syncing everything in a single pass would saturate NeoSync's servers. Instead, each game is synchronised as you reach it:

- **Whenever NeoStation walks through your games**, the game you land on is checked and synchronised with the cloud as you browse.
- **When NeoStation starts**, it checks the cloud and downloads any newer saves.
- **Before a game launches**, it pulls down the latest saves, states and memory cards for that game.
- **After you finish a game**, it pushes your local changes up to the cloud.

Because each game is synced one at a time, give it a moment: look for the **sync/checkmark** indicator on the left side of the screen and wait until the synchronisation finishes before moving on or launching the game.

Because of this, you only need to play and let NeoStation handle the rest. You can turn this automatic behaviour **on or off** in the NeoSync settings, but leaving it on is the recommended way to keep everything current.

### What Is Synced

NeoStation saves each file with the system and the emulator (or RetroArch core) that created it. This means:

- Game saves and save states are linked to the game they belong to.
- Memory cards and other shared files are shared across the whole system.
- RetroArch saves are tracked per core, so switching between devices keeps using the right emulator.
- Standalone emulator saves are tracked per emulator, and only sync while their custom save folder is configured.

## Per-Game Status

Each game in your library shows a small cloud status so you know where its save stands:

| Status | Meaning |
|---|---|
| **No save found** | There is no save for this game yet, on this device or in the cloud. |
| **Local only** | The save exists on this device but has not been uploaded yet. |
| **Cloud only** | The save is in the cloud but not on this device yet. |
| **Up to date** | The local and cloud saves match. |
| **Disabled** | Cloud sync is turned off for this game. |
| **Quota exceeded** | Your storage plan is full. Free up space or upgrade. |

You can turn cloud sync on or off for an individual game.

## Save List

The **Save List** shows every file you have in the cloud. You can:

- Browse your online saves, states and memory cards.
- **Search** by name to find a specific save.
- **Filter** by scope (per-game saves or memory cards), system, or emulator.
- **Sort** by newest/oldest or by name.
- **Refresh** the list to show the latest files.
- **Delete** a cloud save.

## Custom Save Folders

Standalone emulators store their saves in folders that NeoStation cannot find on its own. You point NeoStation at the folder once, per system and emulator:

1. Open **Custom Save Folders** in the NeoSync area.
2. Choose the system and the emulator.
3. Select the save folder on your device.
4. Choose **Configure**. NeoStation uploads the folder's existing saves right away.
5. Repeat this for every standalone emulator and system you use.

> **Important:** A custom folder only syncs when it is configured on **every device** you want to synchronise with. NeoStation cannot place a save into a custom folder that the target device has not been pointed at, so configure the same system + emulator + folder on each device.

### Which Folder to Choose

Select the folder that contains the emulator's saves on that device:

- **Switch (Eden, Citron, Yuzu, ...):** the save data folder inside the emulator's NAND, for example `.../Android/data/dev.eden.eden_emulator/files/nand/user/save`. Each game lives under its Title ID inside this folder. Do not select the whole NAND, which also holds non-save data.
- **Memory-card systems (PS2, Dreamcast, ...):** the folder that holds the memory cards or VMU files, for example a `memcards` or `data` folder.

The path is stored **relative to the folder you select**, so any parent of the actual save files works, as long as the other devices have the same folder structure.

Removing a custom save folder only disconnects it from syncing; it does not delete the local files.

## Deleting a Cloud Save

You can delete a cloud save from **NeoStation** (in the **Save List**) or from the [official site](https://neosync.cloud/). NeoStation asks for confirmation before deleting a cloud save.

> **Warning:** Deleting a cloud save is permanent. If you might need a local copy, download it from the [official site](https://neosync.cloud/) first.

## Downloading a Save

Downloads in NeoStation are **automatic**, triggered by synchronisation: they happen while NeoStation walks through your games and before and after each game session.

There is **no manual download button** in NeoStation. If you want to download a save or memory card by hand, use the [official site](https://neosync.cloud/).

## Legacy (v1) Saves

Saves from the previous NeoSync version are kept as **backup only**. Legacy saves are not synced by NeoStation and can only be downloaded as a backup from the [official site](https://neosync.cloud/).

From now on, NeoStation only uses the new **NeoSync v2** cloud storage for normal synchronisation. Standalone emulator saves are always uploaded to v2 through their custom save folder; nothing is uploaded to the old layout.

## Storage and Plans

Your NeoSync account has a storage limit. When you are close to the limit, NeoStation shows how much space you are using and how much remains. If you run out of space, syncing pauses so you can free up room or upgrade your plan.

## Related Pages

- [Troubleshooting](/troubleshooting/)
- [Configuring Emulators](/configuration/configuring-emulators/)
