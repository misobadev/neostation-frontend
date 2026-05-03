# Adding Systems and Emulators

Each file in this folder defines one system (console/platform) and all its supported emulators. The filename matches the system ID (e.g. `genesis.json`, `psp.json`).

## File Structure

```json
{
  "system": {
    "id": "genesis",
    "name": "Sega Genesis",
    "short_name": "Genesis",
    "folders": ["genesis", "Sega Genesis"],
    "extensions": ["bin", "md", "smd", "zip"]
  },
  "emulators": [ ... ]
}
```

### `system` fields

| Field | Description |
|---|---|
| `id` | Unique system ID, must match filename (without `.json`) |
| `name` | Full display name |
| `short_name` | Short display name |
| `folders` | ROM folder names the app will scan |
| `extensions` | Supported ROM file extensions (no dot) |

---

## Emulator Entry

```json
{
  "name": "RetroArch Genesis Plus GX",
  "unique_id": "genesis.ra.genesis_plus_gx",
  "default": true,
  "description": "Supported extensions: bin, md, zip.",
  "is_retroachievements_compatible": true,
  "platforms": {
    "android": {
      "launch_arguments": "..."
    },
    "windows": {
      "executable": "retroarch.exe",
      "args": "-L genesis_plus_gx_libretro.dll \"{file.path}\""
    }
  }
}
```

| Field | Description |
|---|---|
| `unique_id` | Unique ID, format: `{system_id}.{type}.{core}` |
| `default` | `true` marks this as the default emulator for the system |
| `is_retroachievements_compatible` | Whether RetroAchievements work with this emulator |

---

## Android `launch_arguments`

Format follows the `am start` command syntax used by Android. This is the **complete source of truth** for how the app launches a ROM — no extra native code is needed.

### Structure

```
-n <package>/<activity> -a <action> -d "{file.uri}" [extras] [flags]
```

### Placeholders

| Placeholder | Resolves to | Use case |
|---|---|---|
| `{file.uri}` | SAF `content://` URI or `file://` URI for real paths | **`-d` (intent data field)** and URI-type extras |
| `{file.path}` | Raw `content://` URI or raw filesystem path | **RetroArch `--es ROM`** and path-type extras |
| `{tags.steamappid}` | Game title ID / Steam App ID | Steam / PC games |
| `{tags.vita_game_id}` | PS Vita game ID | PS Vita |

> **Rule: `-d` always uses `{file.uri}`. RetroArch `--es ROM` always uses `{file.path}`.**

### Activity flags

Append to control how Android starts the activity:

| Flag | Effect |
|---|---|
| `--activity-clear-task` | Clear the emulator's task stack before launching |
| `--activity-clear-top` | Bring existing instance to top instead of creating a new one |
| `--activity-no-history` | Don't keep this activity in the back stack |
| `--activity-no-animation` | Skip launch animation |
| `--activity-single-top` | Reuse existing top instance if same activity |

Most standalone emulators should have `--activity-clear-task --activity-clear-top --activity-no-history`.

---

## Examples

### Standalone emulator (ACTION_VIEW with URI)

```json
"launch_arguments": "-n org.ppsspp.ppsspp/.PpssppActivity -a android.intent.action.VIEW -c android.intent.category.DEFAULT -d \"{file.uri}\" -t application/octet-stream --activity-clear-task --activity-clear-top --activity-no-history"
```

### Standalone emulator (custom action with extra)

```json
"launch_arguments": "-n me.magnum.melonds/.ui.emulator.EmulatorActivity -a me.magnum.melonds.LAUNCH_ROM -d \"{file.uri}\""
```

### Standalone emulator (path as string extra, no intent data)

```json
"launch_arguments": "-n xyz.aethersx2.android/.EmulationActivity -a android.intent.action.MAIN -e bootPath \"{file.path}\" --activity-clear-task --activity-clear-top"
```

### RetroArch core (64-bit)

```json
"launch_arguments": "-n com.retroarch.aarch64/com.retroarch.browser.retroactivity.RetroActivityFuture --es ROM \"{file.path}\" --es LIBRETRO \"genesis_plus_gx\""
```

### RetroArch packages

| Package | Variant |
|---|---|
| `com.retroarch` | Standard RetroArch |
| `com.retroarch.aarch64` | RetroArch 64-bit |
| `com.retroarch.ra32` | RetroArch 32-bit |

The app automatically appends `_libretro_android.so` to the core name — just write the core base name (`genesis_plus_gx`, `ppsspp`, `melonds`, etc.).

### Extra types

| Flag | Type | Example |
|---|---|---|
| `--es` or `-e` | String | `--es ROM "{file.path}"` |
| `--ez` | Boolean | `--ez autolaunch true` |
| `--ei` | Integer | `--ei mode 1` |
| `--el` | Long | `--el id 12345` |
| `--ef` | Float | `--ef speed 1.5` |

---

## Adding a New Emulator to an Existing System

1. Open the system JSON (e.g. `assets/systems/genesis.json`)
2. Add a new entry to the `emulators` array
3. Set a unique `unique_id` with format `{system_id}.{type}.{name}`
4. Add the `platforms.android.launch_arguments` following the rules above
5. Optionally add `platforms.windows`, `platforms.linux`, `platforms.macos`

**Example — adding a new standalone emulator for Genesis:**

```json
{
  "name": "Standalone MyGenEmu",
  "unique_id": "genesis.com.example.mygene",
  "description": "Supported extensions: bin, md, zip.",
  "is_retroachievements_compatible": false,
  "platforms": {
    "android": {
      "launch_arguments": "-n com.example.mygene/.MainActivity -a android.intent.action.VIEW -d \"{file.uri}\" --activity-clear-task --activity-clear-top --activity-no-history"
    }
  }
}
```

---

## Adding a New System

1. Create a new file `assets/systems/{system_id}.json`
2. Register it in the app's system list (contact a maintainer if you don't know where)
3. Follow the structure above

**Tips:**
- Use an existing similar system as a template
- `unique_id` must be globally unique across all systems
- Test with `adb shell am start ...` before adding to the JSON to verify the intent works

---

## Desktop platforms

For Windows, Linux, macOS use `executable` + `args`:

```json
"windows": {
  "executable": "retroarch.exe",
  "args": "-L genesis_plus_gx_libretro.dll \"{file.path}\""
}
```

`{file.path}` always resolves to a real filesystem path on desktop — no SAF involved.
