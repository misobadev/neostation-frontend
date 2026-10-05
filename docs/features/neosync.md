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

### RomM Saves

The RomM manager lists the connected user's remote saves and states, newest
first, including archival versions and conflict backups. Use the filter button
to switch between all files, saves, and states. **Refresh** (X) reloads the
inventory without transferring saves.

**Retry uploads** (Y) checks local games linked to RomM with save sync enabled
and retries pending uploads using the existing conflict protections. It does
not download all remote saves: downloads run before a linked game launches.
Per-game and per-system sync settings still apply. Failed requests show an
error rather than an empty inventory or a successful upload check.

**Delete** (Select) permanently removes the focused file from the RomM server
after you confirm. Files on your devices are not touched, so a device that
still syncs the game uploads its copy again on its next sync. Deleting needs
the same `assets.write` permission as uploading.

Use the D-pad to navigate the controls and files, A to activate a control,
L1/R1 to change tabs, and B to return to Systems.

## The Official Site

The official NeoSync website is [https://neosync.cloud/](https://neosync.cloud/). You can sign in or create an account there exactly as you can in the NeoStation app.

## Sign In or Create an Account

Open the **Saves** tab with NeoSync selected and choose to create an account or sign in. You can also do this on the [official site](https://neosync.cloud/).

- New accounts need email verification. NeoStation can resend the verification email.
- If you forget your password, use the password recovery option.

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

Some standalone emulators store their saves in a folder that NeoStation cannot find automatically. You can point NeoStation at it:

1. Open **Custom Save Folders** in the NeoSync area.
2. Choose the system and emulator.
3. Select the save folder on your device.
4. Choose **Configure**, then **Sync now** when you want to back up or pull down that folder.

> **Important:** For a custom folder to sync, it must be configured on **every device** you want to synchronise with. NeoStation cannot place a save into a custom folder that the target device has not been pointed at, so configure the same system + emulator + folder on each device.

Removing a custom save folder only disconnects it from syncing; it does not delete the local files.

## Deleting a Cloud Save

You can delete a cloud save from **NeoStation** (in the **Save List**) or from the [official site](https://neosync.cloud/). NeoStation asks for confirmation before deleting a cloud save.

> **Warning:** Deleting a cloud save is permanent. If you might need a local copy, download it from the [official site](https://neosync.cloud/) first.

## Downloading a Save

Downloads in NeoStation are **automatic**, triggered by synchronisation: they happen while NeoStation walks through your games and before and after each game session.

There is **no manual download button** in NeoStation. If you want to download a save or memory card by hand, use the [official site](https://neosync.cloud/).

## Legacy (v1) Saves

Saves from the previous NeoSync version are kept as **backup only**. Legacy saves are not synced by NeoStation and can only be downloaded as a backup from the [official site](https://neosync.cloud/).

From now on, NeoStation only uses the new **NeoSync v2** cloud storage for normal synchronisation.

## Storage and Plans

Your NeoSync account has a storage limit. When you are close to the limit, NeoStation shows how much space you are using and how much remains. If you run out of space, syncing pauses so you can free up room or upgrade your plan.

## Related Pages

- [Troubleshooting](/troubleshooting/)
- [Configuring Emulators](/configuration/configuring-emulators/)
