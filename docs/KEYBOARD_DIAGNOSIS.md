# Keyboard open lag: diagnosis record (Sep 2026)

TODO: re-evaluate. Small keyboard issues still show up in daily use, and parts of this record are known to be wrong.

## Verdict

The lag after unfocus is the platform cold-restart path (`setClient` plus
full `startInput` inside the keyboard window), not app frames. Every app-side
metric ever captured was clean during graded-laggy opens: steady 16-18ms
presents, 0 jank, 0 missed vsync, 1 layout per list per frame. Neither Gboard
nor Samsung is at fault specifically; both pay the same restart. Reference
apps survive only because they never go cold (testapp has no focus
management; chatsen re-requests focus on send and unfocuses solely on
tap-away). Rule: never close the composer connection except on explicit
field switches. Hide, do not unfocus.

## Trigger table (all verified on device)

- Fresh install, first tap: smooth.
- Any composer unfocus (settings pre-unfocus, manual unfocus, back):
  all subsequent opens lag, on Gboard and Samsung.
- Swipe close retaining focus, then tap: smooth.
- Plain `setState` rebuild: does not trip.
- List-only detach/remount: does not trip.
- Whole-ChatBody detach (disposes TextField): trips (confounded, see below).
- Settings trip with hide-only (focus kept): still lags, because the pushed
  route steals focus on cover regardless.
- Single-line bare probe bar: still lags. Input shape exonerated.
- Send-a-message heals the channel: confounded twice (once by list branch
  swap, once by time passing). Do not rely on it.

## Exonerated with evidence

- Emotes/animation: empty channel plus animations-off still lags.
- Glass: non-glass layout still lags (post-unfocus lag). Also exonerated for
  the rare snap (it happens in opaque too). It remains the dominant raster
  cost during the animation, but that is a separate, unmeasured claim.
- `flutter_list_view` remount: list-only detach is a no-op; per-list
  layouts are 1/frame smooth and laggy alike (`DIAGLAYOUT`).
- Shell rebuilds, `LayoutBuilder` replays, delegate churn: real waste,
  fixed anyway, but not the trigger (perfect tables with them present).
- Input shape: multiline flag, formatters, decoration identical-behaving;
  probe bar changed nothing.
- Gboard internals: Samsung reproduces identically.

## Kept fixes (behavior preserving, test green)

- Emote stream start stagger by URL hash plus max 3 concurrent decodes
  (`lib/widgets/emote_url_provider.dart`). Spreads bulk-restart decode
  cost instead of stacking it into one frame.
- Granular `MediaQuery` aspects in the app root wrapper and `TabbedLayout`
  (`lib/main.dart`, `lib/widgets/tabbed_layout.dart`). Same output, fewer
  aspect subscriptions.

## Reverted: looked good, regressed correctness

- Fork `update()` gating (never invalidate on same-delegate updates):
  caused 3 `chat_test` failures via stale rows. Same-delegate updates must
  still rebuild because content (tile cache, prefs) changes under a cached
  delegate instance. Fork pin stays at `8b5e7ae`.
- Empty-delegate cache: same staleness mechanism, unproven benefit.

## Reverted as unproven or behavioral

- Emote motion hold, vsync-quantized emission, motion resume: built for a
  stale pairs table; complexity without a confirmed trigger.
- Sticky focus, hide-only settings/back/PiP/panels, visibility back guard:
  correct direction, but unfocus is core UX; revisit as a product decision.
- All diag instruments (FABs, counters, prints, probe bar, testapp probe).

## Composer sync: the 1-vsync offset and the rare snap (addendum)

The verdict above is the post-unfocus cold-restart lag. This addendum is a
different symptom: the composer's motion *during* a keyboard gesture.

### The 1-vsync offset (measured, imperceptible)

- A minimal repro (Scaffold + Column + TextField, no glass) with a native
  per-frame `WindowInsetsAnimation` sampler and vsync-stamped Dart frames
  measured `sample lag (median): 1 vsync`: the composer's laid-out inset on
  frame N equals the platform `onProgress` from N-1, at both 1x and 5x
  animator scale. It looks pixel-perfect to the eye.
- Structural: the frame built in Choreographer frame `k` consumes the
  `onProgress` from frame `k`. iOS fixes this with forward projection
  (`FlutterKeyboardInsetManager`); Android has no equivalent. Fixing it is an
  engine change, not app code, and the visible payoff is ~nil.

### The rare snap (reproduced in a widget test, NOT confirmed on device)

- Symptom: "smoothly goes, suddenly snaps, snaps back, keeps going"; rare;
  happens in BOTH glass and opaque, so it is mode-independent.
- Candidate cause: the engine defers only `WindowInsets.Type.ime()`
  (`ImeSyncDeferringInsetsCallback.java`), so a nav-bar (`systemBars`) hide is
  delivered un-animated while the IME is still inside the safe-area dead
  zone. The composer parks at `screenH - max(viewInsets, viewPadding)`, so
  `max(...)` drops and the composer falls, then the rising IME lifts it back.
  A one-frame `viewInsets = 0` (TextInput client reset) does the same.
  Reproduced frame-by-frame in a widget test (commit `9146742`; reverted with
  the hold below).
- An app-side monotonic hold ("composerPad") made that widget test pass but
  did NOT change the symptom on the SM S721W. Tried and reverted; cause still
  open.

### Composer geometry and history

- Composer bottom = `screenH - max(viewInsets, viewPadding)`; pinned for the
  first ~`viewPadding` (~45dp) of travel (safe-area dead zone), then follows.
- v0.2.2-v0.7.0 used `resizeToAvoidBottomInset: false` + a direct
  `Padding(bottom: viewInsets + padding)` (no animator, no size animation).
  `b505e07 "optimize keyboard"` switched to `resizeToAvoidBottomInset: true`
  because the direct path stuttered horribly (and a 30fps regression). Do not
  revert that blindly; the direct path is not a free win.
- The minimal repro uses the Scaffold-resize path and is smooth.

### Kept fixes (composer, test green)

- Safe-area `Padding` moved outside the composer `AnimatedSize` so the nav-bar
  collapse is not animated (`lib/widgets/chat_body.dart`).
- Pill double-count guard: the outer padding is 0 while the pill floats; the
  pill keeps its own `bottomPad + kGlassComposerMargin`.
- `_pillShown` 240ms backstop so a missed `AnimatedOpacity.onEnd` cannot leave
  the pill mounted.
- One shared `inputBarKey` on both the pill and the in-flow wrapper, so the
  composer's `FocusNode` reparents instead of being recreated, with the two
  paths gated mutually exclusive. Fixes the opaque field being unselectable.

### Ruled out for the snap

- Glass: mode-independent.
- `MultipleCallsToSecondaryVsyncInFrameInterval`
  (`shell/common/vsync_waiter.cc`) is a benign dedup trace, not an error.
- `_liftH` value: only its 0-crossing is read (`keyboardH > 0`), never the
  magnitude.
- `showStreamVideo`: for 384x832 @ 300dp keyboard / 14pt it never crosses.
- Pill relocation / chrome collapse: does not fire in portrait (open height
  476 > the 300 threshold).

## Open questions

- Why the very first cold open is smooth while later restarts lag (likely
  IME per-app restore state; unverified).
- Whether `layouts=4` aggregate (2 pages x rebuild+layout) can drop to 2.
- Focus restore on settings pop: `DIAGFOCUS` trail was added but never
  graded; it decides whether refocus-on-return is a viable warm path.
- Rare mid-gesture snap: cause unconfirmed. Nav-bar (`systemBars`)
  non-deferral is the leading candidate and is reproduced in a widget test,
  but an app-side monotonic hold did not change it on device. Needs the
  per-frame trace (composer bottom vs `viewInsets`/`viewPadding`) to catch it
  live.
- The old "regresses to 30fps" bug: still unsolved, and not the same as the
  snap.
