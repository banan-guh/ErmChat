# Keyboard open lag: diagnosis record (Sep 2026)

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
- Glass: non-glass layout still lags.
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

## Open questions

- Why the very first cold open is smooth while later restarts lag (likely
  IME per-app restore state; unverified).
- Whether `layouts=4` aggregate (2 pages x rebuild+layout) can drop to 2.
- Focus restore on settings pop: `DIAGFOCUS` trail was added but never
  graded; it decides whether refocus-on-return is a viable warm path.
