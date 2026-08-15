# Native WebP Decoder Plan (libwebp via FFI + git submodule)

## Top note: libwebp ships as a git submodule (DECISION)

F-Droid is the distribution channel, so all native code must build from source on
F-Droid's build server with no prebuilt binaries and no build-time downloads.

- **Chosen mechanism: git submodule** pinned to libwebp tag `v1.4.0` (commit
  `845d5476...`) from the GitHub mirror (`https://github.com/webmproject/libwebp`).
  F-Droid's own metadata docs recommend submodules over srclibs ("Because srclibs
  can't be updated automatically, git submodule is a better choice."), and the F-Droid
  recipe only needs `submodules: true` (runs `git submodule update --init --recursive`).
- Submodule lives at `third_party/libwebp`; zero library bytes in our git history,
  updates are a one-commit pointer bump.
- **Verify first, submodule later**: prove the whole FFI pipeline works against a local
  libwebp checkout (spike build + decode correctness/speed harness) BEFORE wiring the
  submodule + gradle/podspec plumbing. The spike already proved the decoder is
  pixel/duration-identical to the pure-Dart reference and 19-60x faster; what remains
  to be proven is the shim + FFI integration in-app.

## Goal

Replace the pure-Dart animated-WebP decoder (slow, ~5x slower worst case; engine codec
is pixel-close but janky on ~9% of emotes and non-looping on ~1%) with Google's
canonical `libwebp` `WebPAnimDecoder` via dart:ffi. Keep the pure-Dart decoder as a
fallback (missing lib / decode error / tests without a host build).

## Why not alternatives (decided)

- **pub.dev packages** (`native_animated_image` etc.): ship prebuilt binaries, which
  F-Droid's scanner deletes -> app builds but codec is gone at runtime. Decoders are
  third-party reimplementations (not Google's libwebp), unverified publishers,
  `image-webp`/Rust correctness unproven, AVIF removed upstream.
- **Engine codec**: fixed on our fixtures (frame count/sizes/alpha/durations exact,
  pixel diff <2.5%) but still known-bad on transparent-frame compositing (non-looping
  emotes); can't detect bad output at runtime (subjective).
- **Vendoring libwebp into the repo**: works but ~4-6 MB of third-party source in git;
  submodule is the documented, cleaner dependency mechanism.
- **srclib / FetchContent**: srclib can't be auto-updated and lives in fdroiddata
  metadata; FetchContent downloads at CMake configure time (F-Droid permits it but
  reviewers prefer the documented submodule path).

## Tasks

### 1. Spike: shim + FFI decode harness (VERIFY FIRST - current step)

- [x] Build libwebp 1.4.0 locally (done in `/tmp/opencode/libwebp`): static `libwebp` +
      `libwebpdemux` (contains `WebPAnimDecoder`). Verified: 47-frame kiss = 3.4 ms,
      252-frame boink = 27.0 ms; Dart = 204.6 ms / 515.9 ms; pixel diff (premultiplied)
      1.1% / 2.1%; durations exact.
- [x] Write the C shim `native/emote_codec.{c,h}` and build it on the host against the
      local libwebp.
- [x] Dart FFI bindings + a decode test harness comparing native vs pure-Dart output on
      `test/fixtures/7tv_kiss_2x.webp` / `7tv_boink_2x.webp` (pixel + duration equality).
- [x] Proof gate: shim correctness + FFI loading + in-app `_decodeBytes` dispatch with
      fallback. Only then proceed to submodule + platform plumbing.
- [x] `tool/build_native_linux.sh`: builds libwebp (CMake, static, PIC) + shim into
      `build/native/libemote_codec.so`; verification harness runs via
      `EMOTE_CODEC_SO=build/native/libemote_codec.so flutter test test/verify/`.
      Verified: kiss 9.9x / boink 4.6x speedup, exact durations, 1-2% pixel diff.
      (Skips silently without the env var, so `flutter test` stays green everywhere.)

### 2. C shim (`native/emote_codec.{c,h}`)

- [x] `EmoteDecodedFrames` struct: canvas_w/h, frame_count, loop_count, `int*`
      durations_ms, `uint8_t*` straight-alpha RGBA (w*h*4 per frame).
- [x] `emote_decode_webp(bytes, len, out)` -> WebPAnimDecoder (MODE_RGBA), copy frames
      into one malloc'd buffer; `emote_free_frames()`.
- [x] Keep the API shape format-agnostic so AVIF (`emote_decode_avif`) can slot in
      later behind the same struct.

### 3. Git submodule (only after task 1 passes)

- [x] `git submodule add https://github.com/webmproject/libwebp third_party/libwebp`
      then `git checkout v1.4.0` (commit `845d5476a866141ba35ac133f856fa62f0b7445f`).
- [x] `.gitmodules` + gitlink committed; update `AGENTS.md` (clone instructions gain
      `--recursive` / `git submodule update --init`).
- [x] License note: BSD-3-Clause, add to `THIRD_PARTY_LICENSES`.

### 4. Android build (`android/app/src/main/cpp/CMakeLists.txt`)

- [x] `set(WEBP_BUILD_CWEBP OFF)`, `WEBP_BUILD_DWEBP OFF`,
      `WEBP_BUILD_ANIM_UTILS OFF`, `WEBP_BUILD_LIBWEBPMUX OFF`;
      `add_subdirectory(third_party/libwebp)` -> link `webpdemux` + `webp`.
      (options need `set(... CACHE BOOL FORCE)` to override `option()` defaults;
      AGP 9 dropped the `externalNativeBuild.arguments` DSL hook, so
      `-Wl,--build-id=none` moved into CMakeLists.txt)
- [x] `add_library(emote_codec SHARED native/emote_codec.c)`; include dirs for
      libwebp headers; `-Wl,--build-id=none` for reproducible builds (existing pattern
      in `android/build.gradle.kts`).
- [x] `externalNativeBuild { cmake { path = "src/main/cpp/CMakeLists.txt" } }` in
      `android/app/build.gradle.kts`.
- [x] Build the APK locally + `flutter analyze`/`flutter test`.
      (Local full APK needed a JDK 17/21: system JDK 26 breaks AGP 9's
      JdkImageTransform jlink step; CI uses Zulu 17. APK contains
      `libemote_codec.so` for arm64-v8a/armeabi-v7a/x86_64.)

### 5. iOS build (`ios/emote_codec.podspec`)

- [x] Podspec with `source_files` covering the shim + `../third_party/libwebp/src`
      compile set (dec/demux/dsp/utils/webp); `s.static_framework = true`.
      (F-Droid is Android-only; this serves the GH Actions iOS job.)
- [ ] Verify via CI (`flutter build ios --no-codesign`) on macOS runner.

### 6. Dart FFI bindings (`lib/services/emote_codec/native_emote_codec.dart`)

- [x] `DynamicLibrary.open('libemote_codec.so')` (Android) / `DynamicLibrary.process()`
      (iOS); lazy `isAvailable` probe, cached.
- [x] `decodeWebp(Uint8List) -> EmoteFrameData?`: call C, copy frames, premultiply
      (reuse `_premultiply`), `decodeImageFromPixels` -> `ui.Image`, free C buffer.
- [x] Debug prints `[NativeEmoteCodec]` on load success/failure (mirrors existing
      `[EmoteImage]` style).

### 7. Wiring + fallback (`lib/widgets/emote_image.dart`)

- [x] `_decodeBytes` animated-WebP branch (currently `_decodeWebp` -> `Isolate.run` ->
      `img.WebPDecoder`): try `NativeEmoteCodec.decodeWebp` first, pure-Dart fallback on
      null/throw. Static WebP / GIF / PNG paths unchanged (engine codec).
- [x] Decode stays inside `Isolate.run` (FFI call is isolate-safe); semaphore unchanged.

### 8. Tests

- [x] Existing suite must stay green (fallback path is the default in `flutter test`
      without a host-built `.so`).
- [x] `test/unit/native_emote_codec_test.dart`: gated on host build presence
      (`tool/build_native_linux.sh`); pixel + duration equality vs `decodeWebpPureDart`
      on both fixtures; `isAvailable` false when lib missing; free-path leak sanity.
- [x] Dispatch tests: `test/unit/emote_image_test.dart` covers the fallback when the
      lib is missing; the verify harness covers the native-success path through the
      production pipeline (dispatch output byte-identical to the inline decode).
- [x] `tool/build_native_linux.sh`: builds the shim against the submodule checkout for
      host (used by the gated test group + local verification).

### 9. F-Droid recipe (fdroiddata, outside this repo)

- [ ] Add `submodules: true` to the app's build block (MR to fdroiddata).
- [ ] Confirm CMake/NDK toolchain needs (standard F-Droid native path).

## Out of scope (later, separately)

- **AVIF**: libavif + dav1d, same shim/FFI plumbing (`emote_decode_avif`). No provider
  emits AVIF today; the shim API stays format-agnostic so it slots in without rework.

## ImageCache migration (done)

`EmoteClipRegistry` (custom clip cache + manual Ticker playback) was retired in favor of
the stock `Image` widget + stock `ImageCache` via `EmoteUrlProvider`
(`lib/widgets/emote_image_provider.dart`):

- `EmoteUrlProvider extends ImageProvider`, keyed by URL: animated WebP decodes through
  the reinforced decoder, everything else through the stock engine codec
  (`MultiFrameImageStreamCompleter`). In-flight fetches of the same URL dedup via the
  cache; one completer per URL = shared playback clock across widgets.
- `_EmoteImageCompleter` plays `EmoteFrameData` with a Timer (pauses when the last
  listener detaches, resumes on re-attach), frees all frames in `onDisposed`, and
  self-evicts from the ImageCache on error so failed loads retry on the next widget
  (the stock cache keeps errored completers in `_pendingImages` forever).
- Frames are handed to the completer as refcounted `ui.Image.clone()` handles, so
  `setImage`'s per-emission disposal never frees the cached originals.
- `EmoteImage` is now a thin stock-`Image` wrapper: the loading overlay (bare shimmer
  or a cached smaller scale under a faint shimmer) lives inside `frameBuilder`
  (bounded/unbounded safe via LayoutBuilder); `errorBuilder` handles failures.
- Accepted trade-offs: byte accounting is stock (`w*h*4` per entry, i.e. one frame),
  so the 100MB cap undercounts animated entries ~frameCountx; the 1000-entry cap is
  the effective bound. Decode semaphore (10) moved into the provider.

## Verification

`dart format .`, `flutter analyze`, full `flutter test`, device/emulator run with the
native lib (check `[NativeEmoteCodec]` load line + emote menu speed), F-Droid recipe
with `submodules: true`.
