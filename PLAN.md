# Emote Scale URLs + Cached-Placeholder Plan

Goal: make the emote image stack scale-aware and stop showing a blank/shimmer box while
an emote's required resolution is fetching. Three cached-source rules, then a model
change to give every emote its full set of scale URLs.

## Resolved scope

- **`GenericEmote` URLs become scale-aware**: keep `url` (active render URL, e.g. 2x)
  as-is for minimal churn, add `url1x` and rename `urlLarge` -> `url3x`. 7TV is the
  only provider producing a genuinely distinct 3x/file, so `urlLarge` was really only
  correct there; the extra field still future-proofs BTTV/Twitch.
- **Sheet resolution is always "best scale still in cache"**, not tier-picked:
  regardless of Nothing/Low/Medium/High, the emote sheet/menu picker shows the largest
  scale that is still cached, falling back to smaller cached scales as placeholders.
  (In practice the best scale is 2x for 7TV since that is its chat default, but the
  logic is not hard-coded.)
- **"Still loading" placeholder = the smaller cached image with the shimmer sweep kept
  faintly on top**, not a plain image and not a bare shimmer box.

## The cached-source rule (as confirmed)

When a render surface needs an emote at a *required resolution*:

1. **Exact match cached** (need 2x, cache has 2x) -> use it directly. Already works via
   `EmoteClipRegistry.tryAcquireCached` (decoded frames) and `getFileStream` yielding a
   valid cached `FileInfo` first.
2. **Smaller variant cached** (need 2x, cache has 1x) -> render the small cached image
   as the placeholder while the required resolution fetches, with the shimmer sweep kept
   faint on top; swap in the real emote when it lands.
3. **Nothing cached** -> shimmer only, then the fetched image.

## Tasks

### 1. GenericEmote model (`lib/models/generic_emote.dart`)

- [x] Rename `urlLarge` -> `url3x`; add `url1x` (nullable). Keep `url` = active render
      URL (chat at ~28dp).
- [x] Document the read convention (doc comment on the class):
      `url` is what chat/autocomplete renders; `url1x`/`url3x` are the scale
      alternatives used by the sheet/menu resolution picker and as cached-fallback
      placeholders. `url3x` is only set where the provider has a true 3x (7TV);
      FFZ has no 3x (documented).
- [x] Update `toJson`/`fromJson` (`url1x`/`url3x`), keeping `urlLarge` out.

### 2. Providers emit all scales in-hand (no new fetches)

- [x] `lib/services/emote_providers/twitch_emotes.dart`: `url` = smallScale slot
      (current), `url1x` = the `1.0` scale when the `scale` list contains it,
      `url3x` = largeScale (rename). `_selectScales` now returns `(small, oneX, large)`.
- [x] `lib/services/emote_providers/bttv_emotes.dart`: `url1x` = `/1x`,
      `url3x` = `/3x` (both already constructed as strings); `url` stays `/2x`
      (or `/1x` on low, as today). `url3x` only on high (3x is the heavy asset).
- [x] `lib/services/emote_providers/ffz_emotes.dart`: `url1x` = `urls['1']`,
      `url3x` = `urls['4']` (FFZ has no 3x size; its largest 4x serves as the
      high-res sheet/menu asset since the sheet needs sharper than 2x).
- [x] `lib/services/emote_providers/seven_tv_emotes.dart`: capture `first`/`best2x`/
      `lastLe3` into `url1x`/`url`/`url3x` (7TV files are ordered smallest -> largest;
      `lastLe3` caps at 3x, never 4x; `url1x` only when it differs from `url`).

### 3. Shared scale-URL plumbing

- [x] `lib/screens/home_screen.dart` (~1144): the per-owner `GenericEmote` clone must
      forward `url1x`/`url3x`.
- [x] `lib/services/emote_manager.dart:767` (7TV removal URL list) + `:784` (rename
      clone): forward/sweep all scales (`[url, url1x?, url3x?]`).
- [ ] Precache/usage touch sites that only touch `emote.url` may optionally touch all
      stored scales so the smaller files get use-priority too - confirm benefit before
      spreading (precache writes the fetch-size file; smaller files only exist if a
      lower tier fetched them).

### 4. Faint-shimmer cached placeholder in `lib/widgets/emote_image.dart`

- [ ] `EmoteImage` gains an optional `alternateUrls` (smaller scale URLs, e.g. the
      emote's `url1x`) alongside the required `url`.
- [ ] While the required URL's `_load` is in flight (fetch/parse), probe the smaller
      scale URLs, in order, via `EmoteCacheManager().getFileFromCache(url)` (reads the
      repo regardless of cap) and/or `EmoteClipRegistry.tryAcquireCached`: on the first
      hit, decode those bytes (same `_decodeBytes` path, as a throwaway placeholder
      clip, not the shared playback `_EmoteClip`) and render the frames under a faint
      `Shimmer.fromColors` sweep (`Opacity`-reduced highlight) to keep the "still
      loading" cue.
- [ ] When the required URL's frames land, tear down the placeholder (release the
      throwaway clip) and swap to the real shared clip.
- [ ] Keep rule 3: bare shimmer when nothing is cached.
- [ ] Test hooks: reuse `debugFetchOverride`/`debugDecodeOverride`; expose the
      placeholder decode path for widget tests (e.g. assert a small-cached frame is
      painted under a `Shimmer` while the required URL is deliberately delayed).

### 5. Emote sheet / menu resolution picker ("best scale still in cache")

- [ ] `lib/widgets/emote_sheet.dart:117`: stop assuming `urlLarge ?? url`. Pick the
      largest of `url3x`/`url`/`url1x` that is still cached (probe repo via
      `getFileFromCache`; on a probe hit pass that URL directly, else fall through the
      rules above). Keep it not hard-coded to 7TV.
- [ ] `lib/widgets/emote_menu_panel.dart` + `autocomplete_dropdown.dart` +
      `analytics_screen.dart`: thread the emote's smaller scale URL into `EmoteImage`
      as `alternateUrls` where the render also has the `GenericEmote` in hand.
- [ ] `lib/widgets/emote_text.dart` `_emoteImage` (span builder + overlay builder):
      thread the base/overlay emote's `url1x` as the alternate when the emote object is
      available (currently a URL-only `_emoteImage`; may need the emote or its
      `url1x`).

### 6. Tests

- [ ] `test/unit/twitch_emotes_resolution_test.dart`: assert `url1x`/`url3x`
      population per tier; no-4x stays.
- [ ] `test/unit/bttv_emotes_resolution_test.dart`: `url1x` = /1x and `url3x` = /3x
      on high, null on low/medium as designed.
- [ ] `test/unit/ffz_emotes_resolution_test.dart`: `url1x` from `urls['1']`,
      `url3x` always null.
- [ ] `test/unit/seven_tv_emotes_test.dart`: `url1x`/`url3x` from ordered files
      (smallest / <=3x), no 4x.
- [ ] `test/unit/emote_image_test.dart`: new widget tests - small-cached placeholder
      renders under faint shimmer while required URL delayed; swap to required frames;
      shimmer-only when nothing cached; alternate-URL probe order.
- [ ] `test/unit/emote_manager_test.dart`: update `urlLarge` references to `url3x`;
      rename/precache/removal URL lists carry all scales.
- [ ] `test/widgets/widget_test.dart` (emote sheet): shows best scale still in cache
      across tiers.

## Verification

`dart format .`, `flutter analyze`, full `flutter test`.