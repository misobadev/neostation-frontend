---
title: Steam Deck & SteamOS
layout: default
nav_order: 4
---

# Steam Deck & SteamOS

NeoStation's Linux build supports Steam Deck. Run its AppImage through Steam so Steam Input presents the Deck controls as a gamepad.

## Add NeoStation to Steam

In Desktop Mode:

1. Download the x86_64 NeoStation AppImage.
2. In Steam, open **Games → Add a Non-Steam Game to My Library**.
3. Select **Browse** and change the file filter to **All Files**; the picker normally hides `.AppImage` files.
4. Select the AppImage.
5. Launch NeoStation from your Steam library, either in Game Mode or with Steam running in Desktop Mode.

## Why Steam Matters

Outside Steam, the Deck may use lizard mode: it presents controls as keyboard and mouse input. This can leave a mouse cursor visible, make A/B behave as Enter/Escape, and leave the bumpers without input. Launching through Steam gives NeoStation a virtual gamepad instead.

## Saved Credentials

On SteamOS (and other gaming distributions such as Bazzite and ChimeraOS),
NeoStation uses its encrypted credential file in both Desktop Mode and Gaming
Mode, without requiring GNOME Keyring. The file and its installation key stay
together in the configured user-data directory (by default,
`~/.neostation/user-data` for the AppImage). Use the same user-data directory in
both modes.

Existing keyring credentials migrate when they are readable, usually in Desktop
Mode. The original is removed only after the encrypted file is saved successfully.
If a keyring-only credential is unavailable in Gaming Mode, launch once in Desktop
Mode to migrate it. Signing out in either mode is permanent: a copy left in the
keyring does not come back.

If the encrypted file can no longer be read (for example after reinstalling the
OS, which changes the machine ID), NeoStation renames it and its key to
`credentials.enc.<timestamp>.bak` and `credentials.key.<timestamp>.bak` and
starts a new file, so you can sign in again. Nothing is deleted.

A saved RomM account opens as connected, so the cached library works offline,
and is checked in the background. Only a server that rejects the credential
reports an error.

## Related Pages

- [Getting Started](/getting-started/getting-started/)
- [Configuring Emulators](/configuration/configuring-emulators/)
- [Troubleshooting](/troubleshooting/)
