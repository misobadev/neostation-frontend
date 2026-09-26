---
title: RetroAchievements
layout: default
parent: Features
nav_order: 1
---

# RetroAchievements

NeoStation connects to your RetroAchievements account so you can browse matched games, achievement progress, recent unlocks, completions, masteries, and per-game leaderboards without leaving the app.

## Sign In

1. Open the **RetroAchievements** tab.
2. Enter your RetroAchievements username.
3. Enter your personal Web API key.
4. Select **Login**.

Use **Get API Key** in NeoStation to open the RetroAchievements control panel, where you can obtain your personal key. NeoStation does not use a shared build-time key. Your API key is used for your account's requests and is stored with the rest of your saved login credentials when the device allows it.

If the device cannot save the credentials, the session can still work until you sign out or close the app. You will need to sign in again next time.

## The RetroAchievements Mini-App

After you sign in, the tab is divided into four sub-tabs: **Profile**, **AOTW**, **Games**, and **Awards**. The visible labels in the pill strip can be selected by touch or with the D-pad. From content, press **B** to return focus to the strip; **Left/Right** then switches sub-tabs. The active sub-tab owns its data loading, so switching away does not keep its spinner or requests running.

### Profile

Profile leads with your avatar, standing, points, account mode, and compact lifetime metrics. Achievement of the Week is the primary pursuit, followed by controller-addressable previews of Recent Unlocks and Games. Selecting a preview opens the same game achievement page as the full list.

### AOTW

**AOTW** shows the current year's Achievement of the Week calendar. Past weeks use the event achievement artwork and account progress returned by the API, and are marked as earned casually, earned hardcore, missed, or unknown when a result cannot be verified; future weeks use placeholder icons. The segmented progress bar shows earned and missed weeks. Select a week to open its achievement.

### Games

**Games** combines your recently played games with your completion-progress games into one list. Use the filters to show **All**, **Mastered**, or **Beaten** games. Beaten includes games with a beaten casual, beaten hardcore, completed, or mastered award; mastered remains available as its own narrower filter. The list is loaded in pages as you move through it, including when a filtered result is beyond the first page. Selecting a game opens its RetroAchievements page.

### Awards

**Awards** is a trophy cabinet for mastered, completed, and beaten games. Each tile uses a silver casual border or gold hardcore border. Moving through the grid shows the game title, award type, and highest-award date below the grid.

## Game Achievements

Selecting a game from **Games**, **AOTW**, or a Profile preview opens a dedicated RetroAchievements page keyed by the game's RA ID. The page shows the artwork, console, a combined casual/hardcore progress bar, and the complete achievement list. Use the **All**, **Locked**, and **Missable** filters; Missable includes only locked missable achievements. Each row shows its badge, description, points, available unlock date, and casual/hardcore rarity when the API provides valid counts. Select a row to open its inline detail panel; the Comments action is available with the controller **A** button. An external guide action appears only when the game supplies a valid web URL.

The game page also contains a **Leaderboards** view. It loads only when opened, shows paginated entries, and highlights the signed-in user's entry when RetroAchievements returns one. A game can have no leaderboards or no entries even when the game itself is matched.

## Match Your Library

NeoStation can match new ROMs after the startup scan. To process your whole library with visible progress:

1. Open **Settings → Tools**.
2. Select **Match RetroAchievements Games**.

Matching reads unmatched ROMs to identify them. It can take several minutes for a large library. Selecting the tool again pauses it; completed matches are kept and a later run continues. Disc images are sampled, but NeoStation does not move or delete files while matching.

You can run matching while signed out, but you must sign in to see RetroAchievements results. When a match needs correcting, NeoStation provides a RetroAchievements title search for a manual match.

## Offline Use

NeoStation caches successful RetroAchievements responses on the device. If the network is unavailable and cached data exists, the tab can show the last synced results and displays an offline banner. New data and uncached pages need a connection; reconnect before opening them.

## Sign Out

Disconnecting signs you out and removes the saved RetroAchievements credentials from that device. Cached account data is cleared with the session.

## Related Pages

- [Adding Your Games](/library/adding-your-games/)
- [Troubleshooting](/troubleshooting/)
