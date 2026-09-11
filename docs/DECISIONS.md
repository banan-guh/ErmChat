# Decisions

The rationale and current state for later readers, including fresh agent sessions. The
rules themselves live in `docs/ARCHITECTURE_RULES.md`. This file records why the
architecture is shaped the way it is, so a future session does not relitigate settled
choices or mistake a deliberate tradeoff for an oversight.

## Decision log

Locked decisions, matching PLAN.md.

### D1: Riverpod is the DI, state, and observation framework

Decision: adopt Riverpod for dependency injection, scoping, disposal, and observation.

Reason: compile-safe DI with no `BuildContext` and no locator, `autoDispose` plus
`ref.onDispose`, `ProviderContainer` overrides in tests, and fine-grained `select`. It is
chosen for rules, consistency, lifecycle correctness, and additive-friendliness, not for
fewer lines.

Accepted tradeoff: pin the version and treat upgrades as deliberate projects, and accept
the one sanctioned kernel bridge for the mutable engine.

### D2: Keep the mutable chat kernel

Decision: `Chat -> Channel -> children` stays the domain state model and stays mutable.

Reason: it provides atomic multi-child ingest through `Channel.receive`, one message
source of truth, a thread index, and cross-channel aggregates. It is the domain model,
not pipeline logic, so decentralizing pipeline logic does not remove it. Immutable state
costs a copy plus a sort per message and breaks the 5000-message target.

Accepted tradeoff: one framework-agnostic exception observed through Flutter
`Listenable` builders instead of Riverpod.

### D3: UI migration is observation only

Decision: migrate how widgets observe and obtain shared state, and change nothing else.

Reason: the access and observation layer is where manual listen and dispose, `late final`
init order, and the composition root in a screen live. Layout, copy, and styling are not
the problem.

Accepted tradeoff: visuals stay frozen, so parity is checked with a manual checklist
rather than a golden that would only add churn.

### D4: No fat runtime object

Decision: there is no `ChatRuntime` bundle. App-scope providers each produce one thing,
and screen-scope `autoDispose` providers hold view-only state.

Reason: a single object bundling transports, kernel, pipeline, and managers is a new god
object. The provider graph is the hub and preserves ownership without the bundle. This is
the data and UI split: non-UI state is app-scope providers, UI state is screen-scope
providers.

Accepted tradeoff: more provider declarations and a graph to read instead of one object
to pass around.

### D5: Ring buffer later

Decision: a true O(1) prepend buffer is a `Messages`-internal change behind the existing
API, scheduled as its own phase.

Reason: keep the hot-path storage change separate from the access migration so each can
be verified on its own.

Accepted tradeoff: the backing list stays an O(n) prepend until the ring-buffer phase.

### D6: Codegen later, separate

Decision: no codegen in this plan. `json_serializable` for models and prefs plumbing is a
later, separate track.

Reason: keeping the migration mechanical and reviewable avoids generating a large diff
that hides the access changes.

Accepted tradeoff: models and prefs keep hand-written serialization for now.

### D7: Scope is chat and main architecture

Decision: the plan covers the chat path and the main app architecture. Emotes, settings,
and other feature refactors are deferred.

Reason: bound the blast radius and keep the suites green every commit.

Accepted tradeoff: the deferred areas keep their current wiring and wait for their own
pass.

### D8: Leak audit is light and parallel

Decision: a light leak audit runs alongside the migration and does not gate it.

Reason: the framework does not fix leaks, and a full audit would derail the access work.

Accepted tradeoff: known leak debt stays until it gets its own dedicated pass.

### D9: Rules live in exactly one file

Decision: `docs/ARCHITECTURE_RULES.md` is the single source for architecture rules.
AGENTS.md only points to it and holds operational facts. `docs/DECISIONS.md` holds the
rationale, and the architecture test enforces the mechanical subset and names the rule
it checks.

Reason: one source prevents the rules from drifting between documents.

Accepted tradeoff: AGENTS.md cannot restate architecture rules, so readers follow the
pointer.

### D10: Kernel migration is optional and post-Phase 3

Decision: migrating the engine into Riverpod notifiers happens only if both Phase 6
criteria hold: the bridge feels leaky or the kernel is an island, and Spike B shows an
immutable path within about 10 percent of the mutable engine on the 5000-message burst.
It is not scheduled.

Reason: consistency is not worth a hot-path regression, and the engine is isolated
behind one API and one bridge, so the door stays open.

Status: Spike B (`docs/SPIKES.md`) puts the cheapest immutable path at 2.65x to 3.77x the
mutable engine, so criterion 2 fails and the migration is not triggered. The engine stays.

Accepted tradeoff: the one sanctioned exception may remain indefinitely.

## Why

- **Why a framework at all**: the app is leaving a churn phase and needs rules. It
  hand-rolls access and lifecycle today and gets them wrong with manual listen and
  dispose, `late final` init order, and a composition root inside a screen. A framework
  gives those rules for free. It is chosen for rules, consistency, lifecycle, and
  additive-friendliness, not for fewer lines and not to fix leaks.
- **Why Riverpod**: it gives compile-safe DI without a locator, `autoDispose` plus
  `ref.onDispose`, `ProviderContainer` overrides in tests, and `select`. The accepted
  cost is the one sanctioned bridge for the mutable chat engine.
- **Why keep the mutable engine**: atomic multi-child ingest, one source of truth, a
  thread index, cross-channel aggregates, and the 5000-message target. It is the domain
  model, not pipeline logic.
- **Why no fat runtime object**: a single object bundling transports, kernel, pipeline,
  and managers is a new god object. Providers give the same ownership without the
  bundle.
- **Why not a dankchat port**: Kotlin plus Compose plus Android does not map to Dart
  plus Flutter. dankchat has its own god objects, including `MainFragment`,
  `ChatRepository`, and `MainViewModel`, and a port would discard our dual-socket IRC,
  EventSub scope, and kernel without removing the hard decisions.
- **Why not a global locator or event bus**: reachability and hidden coupling are what
  made the app hurt before the extractions. Scoped providers and typed notifiers preserve
  that fix. One typed notifier per owner stays.
- **Why the kernel migration is optional**: consistency is not worth a hot-path
  regression. The decision comes from the bridge's feel and Spike B's numbers, not from
  a preference for uniform code.

## Current state

- `v0.8.0` and the extraction plus provider-migration commits are on the tree.
  `dart analyze lib test tool` is clean and 1,084 tests are green.
- Eight chat-pipeline owner extractions have shipped: `ChatLifecycle` (683),
  `ChatIngestion` (662), `ChatChannelSetup` (378), `ChatSender` (227),
  `ChatStatusComposer` (163), `JoinProgressTracker` (132), `ChatReadiness` (97),
  `SevenTvConsumer` (124), `EventSubConsumer` (624), and `EventSubTopics` (386).
- `ChatConnectionManager` is a 586-line composition root and facade, down from 1,649
  lines. It builds and disposes the pipeline owners and exposes phase, readiness, send,
  and gating queries.
- `lib/providers` is the composition root. App-scope providers own the transports, the
  managers, the kernel (`Chat`), `Session`, the feature owners (`TwitchAuth`,
  `AnalyticsService`, `NotificationService`, `TtsController`, `ModActions`,
  `ChatNoticeController`, `BroadcastWidgets`, `CommandHandler`), the read-state the
  pipeline consumes (selected channel, max messages, reply-to, blocked logins,
  shared-chat mode, chat readiness, macros), and the chat pipeline
  (`ChatConnectionManager` plus `ChatUiSignals` and the connection-state bridge).
- `HomeScreen` is a `ConsumerState` that consumes providers, forwards `ChatUiSignals`
  to its panels, and keeps only view-only UI state plus the UI-adjacent owners
  (composer, panels, chrome, message builder, emote applier, media upload, panel
  manager, link whitelist, channel notifier).
- The kernel is the domain engine. It is framework-agnostic, reached through a bridge,
  and observes through typed notifiers.
- The architecture test enforces six rules: the original four plus "the pipeline layer
  does not import providers" and "the UI does not construct app objects", the latter
  with a narrow commented allowlist (the `BroadcastWidgets` own constructor declaration
  and the `AccountScreen` `TwitchApi` test seam).
- `ARCHITECTURE.md` maps the whole app with Mermaid diagrams and a "who writes what"
  mutation map.

## Open tradeoffs

- The mutable kernel stays the one non-Riverpod observation path, observed through
  Flutter `Listenable` builders.
- Provider-owned `ChangeNotifier`s (`EmoteManager`, `TwitchAuth`, `ConnectivityService`)
  and the pipeline connection port are bridged to Riverpod tick/state providers so
  widgets use `ref.listen`; the singleton overrides (`twitchAuthProvider`) and the
  Spike A bridge stay intact instead of switching to legacy `ChangeNotifierProvider`.
- The strangler period keeps a temporary adaptor layer and, for a while, both the
  provider path and legacy service params.
- UI-adjacent owners (composer, panels, chrome, message builder, emote applier, media
  upload, panel manager, link whitelist, channel notifier) still construct in
  `HomeScreen`; moving them is deferred.
- The ring buffer is deferred, so message prepend stays O(n) until its phase.
- Codegen is deferred, so models and prefs keep hand-written serialization.
- The leak audit is non-gating, so known leak debt remains.
- The kernel migration is undecided until Phase 6, so the codebase may keep a permanent
  framework-agnostic island.
- Non-chat feature areas keep their current wiring until their own pass.
- The connection-status system lines still fold on text. A stable-id rewrite is deferred
  because it would change how many status lines render, not just how they are matched.
