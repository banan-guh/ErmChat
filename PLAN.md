# Emote Fetching Tiers Plan

Goal: add a settings-driven emote fetching tier (Nothing / Low / Medium / High) plus an
adjustable emote image cache. Tiers control fetch behavior, image resolution, cache
TTLs, and GC aggressiveness. The default is High (current behavior).

## Tier matrix

| | Nothing | Low | Medium | High |
|---|---|---|---|---|
| Fetch global/channel rakes | no | yes, 1x | yes, 2x | yes, 2x |
| Subscriber emotes | no | yes, 1x | yes, 2x | yes, 2x |
| 3x for sheet/menu | - | - | - | on-demand only |
| Metadata cache TTL | n/a | infinite | 48h | 24h (wifi) / 48h (cellular) |
| Disk GC hard TTL | infinite | infinite | 24h | 24h |
| Precache | off | 1x | 2x | 2x |
| Cache cap (emotes) | user slider 0-1500 | same | same | same |

- **4x scrapped entirely.** No provider emits a 4x URL (FFZ `urlLarge`, 7TV largest file).
- **1x -> 2x overwrite:** switching to medium/high triggers a re-resolve; the cache
  tier-tag makes old 1x data stale, so emotes re-store with 2x URLs. Old 1x files become
  untracked and get GC'd.
- **Hoarding:** low/nothing render whatever is already cached (hoarded while on
  medium/high). No hard-TTL eviction on low/nothing; entries persist until LRU-trimmed
  at the cache cap.
- **Hot TTL is gone.** `_gcHotTtl` and its cooldown branch are removed. GC = per-tier
  hard-TTL eviction + pure LRU trim to the cache cap.

## Tasks

### 1. New types

- [ ] `lib/models/emote_fetch_tier.dart`: `enum EmoteFetchTier { nothing, low, medium, high }`
      with `label`/`subtitle` for the settings UI, plus prefs keys
      `'emote_fetch_tier'` (int) and `'emote_cache_max'` (int, 0-1500, default 500).
- [ ] `EmoteResolution { low, medium, high }` in `lib/models/generic_emote.dart`.
      Tier -> resolution: nothing = no fetch, low = low, medium = medium, high = high.

### 2. Custom image cache (`lib/services/emote_cache_manager.dart`)

- [ ] Lazy singleton `CacheManager(Config('emoteImageCacheV2', maxNrOfCacheObjects: 2000,
      stalePeriod: 30d))`. The 2000-file manager cap is a safety net; EmoteManager's GC
      is the real enforcer.
- [ ] `main.dart`: set `CachedNetworkImageProvider.defaultCacheManager = EmoteCacheManager()`
      once at startup so every emote render (chat `emote_text.dart`, emote menu,
      emote sheet, autocomplete, analytics top-emotes) uses the big cache with no
      per-widget threading.
- [ ] `EmoteManager._removeCachedFile` default and `_precacheEmote` use the same
      `EmoteCacheManager()` singleton.
- [ ] One-time migration: `DefaultCacheManager().emptyCache()` under a new
      `emote_gc_migrated_v2` flag (mirrors the existing v1 migration) to clear v1
      orphans.

### 3. EmoteManager (`lib/services/emote_manager.dart`)

- [ ] `_tier` field (default high) + getter/setter (setter notifies).
- [ ] `_cacheCap` field (default 500) + setter; GC uses it.
- [ ] Remove `_gcHotTtl` and the cooldown condition in `runCacheGc`. GC =
      per-tier hard-TTL eviction + LRU trim to `_cacheCap`.
- [ ] `_usageMaxEntries` becomes derived from `_cacheCap` (registry trims to the cap,
      currently a static 300).
- [ ] `_effectiveTtl()` tier-based: high 24h (keep wifi/48h cellular split for high),
      medium 48h, low/nothing `Duration.infinite`.
- [ ] Thread `_resolution` into all provider fetches (`_fetchAllGlobal`, `_fetchAllChannel`,
      `_refreshTwitchGlobalEmotes`, `_refreshTwitchChannelEmotes`).
- [ ] Low/nothing persistence: `_saveToPrefs` includes Twitch non-sub emotes; the
      background Twitch-only refresh branches (`preloadGlobalEmotes` / `resolveEmotes`
      fresh paths) are skipped on low/nothing so infinite TTL means zero per-launch
      network.
- [ ] Nothing-tier guards: `preloadGlobalEmotes`, `resolveEmotes`, `storeUserTwitchEmotes`,
      `updateSevenTvEmotes`, `enqueueSeenEmotes` early-return. `byCode()` still returns
      the hoarded cache so cached emotes render; uncached ones fall back to text.
- [ ] Cache tier-tag: store the `tier` int in the prefs JSON written by `_saveToPrefs`;
      `_loadFromPrefs` treats a mismatched tier as stale so switching tiers refetches at
      the new resolution (the 1x -> 2x overwrite mechanism).

### 4. Providers (resolution param)

- [ ] Add `EmoteResolution resolution` to:
      `TwitchEmoteProvider.fetchGlobal/fetchChannel/fetchEmoteSets`,
      `BttvEmoteProvider.fetchGlobal/fetchChannel`,
      `FfzEmoteProvider.fetchGlobal/fetchChannel`,
      `SevenTvEmoteProvider.fetchGlobal/fetchChannelResponse`.
- [ ] URL selection per resolution (4x never emitted):
      - Twitch: low 1.0/1.0, medium 2.0/2.0 (urlLarge null), high 2.0 + 3.0.
      - BTTV: low 1x/1x, medium 2x/2x, high 2x + 3x.
      - FFZ: low 1/1, medium 2/2, high 2 + urlLarge null (largest is 4x, scrapped).
      - 7TV: low smallest (1x if present, else smallest)/same, medium 2x/2x,
        high 2x + 3x (largest capped at 3x, never 4x).

### 5. Home screen (`lib/screens/home_screen.dart`)

- [ ] Load `emote_fetch_tier` + `emote_cache_max` in init before `_chatConn.connect()`
      and set both on `_emoteManager`.
- [ ] `_applyEmoteTier(int)`: set tier; evict + re-resolve for low/medium/high;
      evict + notify (no fetch) for nothing. Called immediately on slider change.
- [ ] `_applyCacheCap(int)`: set cap + run one GC sweep. Called only after the Apply
      button.
- [ ] `_loadUserEmoteSets`: skip in nothing tier; pass resolution to `fetchEmoteSets`.

### 6. Settings UI

- [ ] New `lib/screens/settings/emotes_settings_screen.dart`: fetch-tier labeled slider
      (4 stops, applies immediately + persists) and a cache-size slider 0-1500 that only
      persists + applies via an **Apply** button (draft value held in state so people
      don't wipe their cache accidentally).
- [ ] Add an "Emotes" tile to `settings_screen.dart` (Icons.emoji_emotions); forward
      `onEmoteTierChanged` + `onEmoteCacheMaxChanged` through `widgets/settings.dart`.

### 7. Tests

- [ ] `test/unit/emote_manager_test.dart`: per-tier TTL, hot-TTL-free GC (LRU trim to cap
      + hard eviction, cap setter), tier-tag staleness (1x -> 2x overwrite via refetch),
      nothing-tier no-fetch guards.
- [ ] Provider tests: resolution variants incl. no-4x (extend `seven_tv_emotes_test.dart`,
      small BTTV/FFZ/Twitch additions).
- [ ] `test/unit/chat_connection_manager_test.dart`: precache skip in nothing tier.
- [ ] `test/widgets/widget_test.dart`: Emotes screen renders tier slider + cache-size
      slider + Apply; nothing tier renders hoarded cache as images, text for unknown.
- [ ] Update `AGENTS.md` structure/test lists.

### 8. Auto tier selection

- [x] `EmoteFetchAutoMode { off, balanced, aggressive }` in `emote_fetch_tier.dart`
      with `label`/`subtitle` and `effectiveEmoteFetchTier(manual, auto, isMobile)`:
      off = manual; balanced = high on Wi-Fi / low on cellular; aggressive =
      medium on Wi-Fi / nothing on cellular. Prefs key `'emote_fetch_auto'`; the
      default (no persisted value) is `balanced`.
- [x] Home screen: load `emote_fetch_auto` in `_loadEmotePrefs`; track the current
      connectivity with `Connectivity().onConnectivityChanged` (`_isMobile`, a live
      `ValueNotifier<bool>`); a `_reconcileEmoteTier()` recomputes the effective tier
      and re-applies it when it changes (launch, setting change, connectivity handoff).
      `_applyEmoteTier` now records the manual tier; `_applyEmoteAutoMode` sets the
      mode; both route through `_reconcileEmoteTier`/`_applyTier`. The notifier is
      passed to the settings screen so the tier slider stays in sync live.
- [x] Emotes settings screen: a three-way `SegmentedButton` (Off/Balanced/Aggressive)
      below the tier slider, in its own "Auto mode" section; switching it on disables
      the manual tier slider with a note and the slider/value label track the
      effective tier (`mobileNotifier`), updating live on connectivity handoffs
      with a `TweenAnimationBuilder` slide (from the current position, never a
      jump) plus `AnimatedSwitcher` crossfades for the tier label and auto note.
      New
      `onEmoteAutoModeChanged` threaded through `settings_screen.dart` /
      `widgets/settings.dart`. A footer (`emote_cache_footer`) shows live disk-cache
      usage: file count + total bytes via `EmoteCacheManager.stats()`
      (`EmoteCacheStats`), refreshed on open and after cache Apply.
- [x] Tests: `test/unit/emote_fetch_tier_test.dart` (resolver matrix, labels, prefs
      keys, default balanced) + widget tests for the switch (persist, callback, slider
      lock/unlock), live connectivity sync, and the cache-usage footer.

## Verification

`dart format .`, `flutter analyze`, full `flutter test`.
