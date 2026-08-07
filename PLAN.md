# Theme Overhaul Plan: DankChat-style grey/black surfaces + True dark toggle

Goal: rework the app theme to mirror DankChat's Material 3 "tonal surface" look -
a neutral grey chrome (app bars, sheets, inputs) on a distinct body surface - and
add a "True dark mode" toggle, defaulting to off.

## How DankChat does it

`DankChatTheme.kt` pins only `surface` + `background` to pure black
(`TrueDarkColorScheme`). Every other M3 tonal role stays at the neutral M3 dark
greys. M3 components then pick their role automatically, which is what creates
the "top is grey, everything else is black" split:

- Body / Scaffold -> `surface` / `background` (black)
- App bar / TopAppBar -> `surfaceContainer` (grey)
- Bottom sheets -> `surfaceContainerLow` (grey)
- Dialogs -> `surfaceContainerHigh`
- Text fields -> `surfaceContainerHighest`

Verified in this Flutter SDK: `AppBar` defaults to `colorScheme.surfaceContainer`
(`app_bar.dart:939`), `BottomSheet` to `surfaceContainerLow` (`bottom_sheet.dart:1496`).

DankChat's "True dark theme" Appearance toggle switches between `darkColorScheme()`
(standard dark) and the black-pinned scheme. Android 12+ layers dynamic color on top
while keeping surface/background pinned.

## Current ermchat state

- `buildLightTheme()`: already neutral greys with a white/grey split - kept as-is.
- `buildDarkTheme()`: `ColorScheme.fromSeed(deepPurple, dark)` with `surface: black`
  only. `background` not pinned; `surfaceContainer*` are purple-tinted, not the
  clean neutral grey of DankChat.

## Tasks

### 1. Theme builders (`lib/main.dart`)

- [ ] `buildDarkTheme({bool trueDark = false})`: base
      `ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark)`,
      then apply a shared neutral grey chrome scale to both variants:
      - `surfaceContainerLowest: 0xFF141414`
      - `surfaceContainerLow: 0xFF1C1C1C`
      - `surfaceContainer: 0xFF222222`
      - `surfaceContainerHigh: 0xFF2A2A2A`
      - `surfaceContainerHighest: 0xFF343434`
      - `surfaceVariant: 0xFF3A3A3A`
      - `outline: 0xFF555555`
      - `onSurfaceVariant: 0xFF9E9E9E`
  - `trueDark == false` (default): body surface ~ `0xFF121212` neutral dark.
  - `trueDark == true`: additionally pin `surface`/`background` to
    `Colors.black` and `onSurface`/`onBackground` to `Colors.white`.
- [ ] `buildLightTheme()`: keep existing neutral grey scale; ensure `background`
      matches `surface` for consistency.

### 2. "True dark mode" toggle (default OFF)

- [ ] `_TwitchChatAppState` (`main.dart`): add `bool _trueDark` loaded from pref
      key `true_dark` (default false) in `_loadPreferences()`; add `_setTrueDark`
      mirroring `_setKeepScreenOn`; pass `darkTheme: buildDarkTheme(trueDark: _trueDark)`
      in both `MaterialApp`s; pass `onTrueDarkChanged` to `HomeScreen`.
- [ ] Thread `onTrueDarkChanged` through:
      `HomeScreen` -> `SettingsButton` (`widgets/settings.dart`) ->
      `SettingsScreen` -> `CustomizationScreen`.
- [ ] `CustomizationScreen`: add `SwitchListTile` "True dark mode" (subtitle:
      "Pure black chat background"), persists to `true_dark` + calls the callback
      (mirror existing "Keep screen on" toggle pattern).

### 3. Where black vs grey lands

- [ ] Settings AppBars pick up grey automatically via `surfaceContainer`.
- [ ] Main chat body stays black via `surface`.
- [ ] Chat widget cutout already uses `surfaceContainerHighest`.
- [ ] **Decision**: the in-house bottom sheets (thread panel, mentions/whispers
      panel, emote menu panel) currently paint `scaffoldBackgroundColor` (-> black).
      DankChat sheets are grey. If matching DankChat: flip those three panels from
      `scaffoldBackgroundColor` to `colorScheme.surfaceContainerLow`.

### 4. Tests

- [ ] Widget test: true-dark toggle in `CustomizationScreen` persists + fires
      callback (mirror existing "Keep screen on" test).
- [ ] Unit test: `buildDarkTheme(trueDark: true)` -> black surface;
      `buildDarkTheme(trueDark: false)` -> non-black surface.
