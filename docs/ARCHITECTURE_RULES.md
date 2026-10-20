# Architecture rules

The rulebook for ermchat, human or agent. Rules here are standing rules, not a
snapshot: they say what new code must do and hold until this file changes.
`docs/ARCHITECTURE.md` is the map of what exists, and `docs/DECISIONS.md` records
why each rule exists plus every sanctioned exception. The architecture test enforces
the mechanical subset; everything else is enforced in review.

Existing code that breaks a code-shape rule is debt, not an emergency. Fix it when
you are already changing that code, and never add to it.

## Layers

```
transport / codec   lib/irc, lib/eventsub/transport, lib/eventsub/decode,
                    lib/archive
        |
      kernel         lib/chat
        |
     pipeline        lib/services
        |
        UI           lib/widgets, lib/screens, lib/chrome, lib/composer,
                     lib/panels, lib/sheets
shared leaves        lib/models, lib/util, lib/client, lib/emotes
composition root     lib/providers
```

- **Transport and codec** turn bytes and frames into typed events. They import their
  own leaves and nothing upward.
- **The kernel** (`lib/chat`) is the domain state model. It is framework-agnostic: no
  services, no UI, no Flutter beyond `foundation`.
- **The pipeline** (`lib/services`) reads transports, applies logic, and mutates the
  kernel through its verbs. It imports no UI, no rendering (`dart:ui`, Flutter
  painting/scheduler/widgets/material) and no providers. The shared `Color` type comes
  through `lib/color_utils.dart`.
- **The emote domain** (`lib/emotes`) is a pure model plus catalog. Render-side emote
  code (image providers, decode, name paints) lives in `lib/widgets`.
- **UI** reads kernel state through providers and the kernel's `Listenable`s, and
  never imports a transport.
- **Shared leaves** are importable from every layer and import nothing upward.
- **Providers** construct the app-scope owners, register their teardown, bridge
  `ChangeNotifier`s to Riverpod, and wire the pipeline.

## Hard rules

1. **One writer per state.** Every piece of state has one owner, and only that owner's
   methods change it. In the kernel, a child's public methods are its verbs, and a
   write that spans several children goes through a `Channel` verb (`receive`,
   `receiveHistory`) so dedup, insert, truncate and index happen in one call. Chat
   data enters only through the pipeline. The UI calls a child verb for two things
   only: reflecting a user action that just succeeded (an unban, a resolved
   redemption) before its echo arrives, and user choices the kernel keeps (pinned
   threads). Never assign another owner's fields, and never let two owners write the
   same value.

2. **One direction of dependency.** Imports follow the layer diagram. When a lower
   layer needs to tell a higher one something, it exposes a typed callback or
   notifier that the higher layer subscribes to.

3. **Shared objects come from providers.** Read a shared service with
   `ref.watch`/`ref.read`. Never construct one in a widget, and never keep a global
   handle to it. Carve-outs: process-lifetime singletons a provider surfaces
   (`PingManager.instance`, `IgnoreManager.instance`), which consumers still obtain
   through the provider, and the settings store `PrefsStore`, a `lib/util` leaf any
   layer may read.

4. **`watch` to react, `read` for one-shots.** Builds are pure. Effects (requests,
   subscriptions, timers) start in lifecycle methods, `ref.listen`, or notifier
   methods, never in `build`.

5. **Owners clean up what they start.** Every resource-owning provider registers
   `ref.onDispose`, and every widget or owner cancels its own timers, subscriptions
   and listeners on dispose.

6. **Small, purpose-named providers.** A provider produces one thing, and its name
   says what. A provider that bundles transports, kernel, pipeline and managers fails
   review.

7. **Owner ports, not parent state.** An owner exposes typed notifiers for what it
   produces and takes a minimal interface for what it needs: typed callbacks, a
   signal sink, or a small host interface. Never store a parent `State` or reach back
   into a screen.

8. **No generic bus.** Each owner exposes typed notifiers or change streams, and the UI
   subscribes to the owner it renders.

## Code-shape rules

1. **One state value, not a flag per case.** When several booleans or nullable fields
   describe phases of one process (loading, replaying, jumping, settled), model them as
   one enum or sealed state. A new edge case adds a state, not another flag that must
   be checked in the right order.

2. **Layout happens in layout.** A size that depends on other widgets' sizes is
   computed during layout (`LayoutBuilder`, `CustomMultiChildLayout`, a render
   object). Measuring through a `GlobalKey` after the frame and feeding the result
   back with `setState` lags a frame and can feed stale or non-finite values forward.
   Where layout truly cannot do it, the measurement carries a comment saying why.

3. **Read settings where they are used.** The widget or owner that needs a pref reads
   it and listens for its change. A screen does not mirror prefs into its own fields
   to hand down.

4. **One owner per behavior.** A second copy of stateful logic (gesture tracking,
   scroll following, drag focus) means extracting one owner both use. Repeating a few
   stateless lines is fine.

5. **Simplify before guarding.** When a fix needs a new flag to suppress one case,
   first check whether a simpler behavior removes the case. Prefer an instant jump
   over an animation that needs guards to stay correct.

6. **Time is injected.** Timing code takes an injectable clock, and per-item periodic
   work joins a shared tick instead of starting a timer per item.

7. **UI values come from the tokens.** Animation durations and curves use `Motion`,
   corner radii use `Radii` (`lib/widgets/design_tokens.dart`), haptics use
   `Haptics` (`lib/util/haptics.dart`), snackbars use `AppSnack`, and dialogs use the
   shared kit in `lib/widgets/dialogs.dart`. A new value means changing the scale, not
   a one-off literal. Haptics confirm what a finger cannot see (holds, drags, crossed
   thresholds); plain taps never buzz. Long-press is a shortcut, never the only way to
   reach an action.

8. **Size is not a rule, coupling is.** There is no line budget. A file that every
   feature has to edit in unrelated places is the signal to extract, along ownership
   lines rather than by line count.

## Sanctioned exceptions

- **Kernel observation.** The kernel's leaf `ValueNotifier`s are observed directly with
  `ListenableBuilder`/`ValueListenableBuilder`. This is the one non-Riverpod
  observation path.
- **Bridges.** A thin adaptor may bridge a `ChangeNotifier` or listener stream to
  Riverpod (`ChangeNotifierTick`, `EmoteStoreNotifier`). It never becomes a second
  writer or a second source of truth.
- **Everything else** is recorded in `docs/DECISIONS.md` with the decision, the reason,
  the scope, and what would remove it. The current list is in the "Known exceptions"
  section of `docs/ARCHITECTURE.md`. An undocumented exception is a bug.
- **Moving state.** Move state once, when its area is reworked. Never move the same
  state twice for tidiness.

## Enforcement

- `test/architecture/architecture_test.dart` enforces layer direction, rendering-free
  pipeline, and provider placement, and each assertion names the rule it checks. Fix a
  failure at the source: no re-export shims, wrapper files, or new carve-outs that
  sneak a forbidden import in, and never weaken the test.
- Ownership, purity, provider size and the code-shape rules are enforced by reading the
  diff.
- When a rule blocks the obvious fix, put the code in the layer allowed to own it. If no
  layer fits, ask before breaking the rule, then document the exception.
