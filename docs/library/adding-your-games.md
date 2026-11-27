---
title: Adding Your Games
layout: default
parent: Library
nav_order: 1
---

# Adding Your Games

NeoStation builds your local library from the folders listed in **Settings → Directories**.

## Add and Rescan Folders

1. Open **Settings → Directories**.
2. Select **Add ROM Folder** and choose a folder.
3. To update the library later, select **Rescan All ROM Folders**.

NeoStation supports a maximum of five ROM folders. Removing a configured folder does not remove any ROM files from storage.

![A ROMs folder containing one subfolder per system, such as gba, n64 and psx](/screenshots/rom-folders.webp)
*A typical ROM folder: one subfolder per system.*

## Subfolders

The **Show Subfolders** setting controls whether games in subfolders are shown in a system. **Show Subfolders in Every System** applies the current setting across systems; you can still change an individual system afterwards.

## Android and Android TV

On Android, choose ROM folders through the system folder picker. NeoStation uses Android's Storage Access Framework, so ROM locations may be represented as storage-provider locations rather than ordinary desktop paths.

On Android TV, NeoStation uses its TV directory picker. If a folder cannot be opened, choose a location Android permits the app to access.

## Remove a Folder

Open **Settings → Directories**, select a configured ROM folder, and confirm **Remove**.

> **Note:** This removes the folder from scanning only. Your ROM files remain in place.

## Related Pages

- [Getting Started](/getting-started/getting-started/)
- [Multi-Disc Games](/library/multi-disc-games/)
- [Troubleshooting](/troubleshooting/)
