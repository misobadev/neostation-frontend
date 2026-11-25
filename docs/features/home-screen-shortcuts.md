---
title: Home screen shortcuts
layout: default
parent: Features
nav_order: 4
---

# Home screen shortcuts

NeoStation can be your home screen. When it is, another launcher's **Add to
Home Screen** files the pinned shortcut into **Android Games** as an entry of
its own — with the game's name and icon, launching that exact game.

## Adding one

1. Set NeoStation as your default launcher (Settings → Apps → Default apps →
   Home app).
2. In the other launcher, long-press a game and choose **Add to Home Screen**.
3. Confirm the system prompt.

The game appears in Android Games straight away. Repeating the pin refreshes the
entry instead of duplicating it; favourites and play time survive.

## Why the entry is not just the app

A pinned game's shortcut usually targets the *launcher* that pinned it, not the
game's package — a DroidDeck pin carries `droiddeck://game/<id>`. Filing the
package instead would collapse every pinned game into one "DroidDeck" entry, so
NeoStation stores the shortcut's own label, icon and launch intent.

## Removing one

Open the entry's options panel and choose **Remove shortcut**. The entry and its
cached icon go; the installed app and any other shortcut are untouched.

## Limits

- Shortcut entries are not scanned, so they survive the rescan and the target
  app being reinstalled. Only removing the entry clears it.
- The pin is accepted on NeoStation's behalf, so the system's own home-screen
  shortcut registry is not what draws these entries — Android Games is.
- Launchers that still broadcast `INSTALL_SHORTCUT` are supported too; a
  shortcut arriving that way needs a label and a launch intent to be usable.
