# Architecture lockdown: adopt Riverpod, keep the chat engine

Status: LIVE PLAN. Supersedes the EventSub reorg plan (that work shipped). This is
written for an implementing agent with zero context. Read the whole document before
touching code. Do not start a phase until the previous phase is green and reported.

Baseline: `v0.8.0` and all extraction commits are on the tree. `lib/` is 54,997 lines,
`test/` is 31,452 lines, 1070 tests green, `dart analyze lib test` clean. The chat
pipeline already owns its logic: `ChatConnectionManager` is 586 lines (a composition
root plus delegators, was 1,649), with `ChatLifecycle` (683), `ChatIngestion` (662),
`ChatChannelSetup` (378), `ChatSender` (227), `ChatStatusComposer` (163),
`JoinProgressTracker` (132), `ChatReadiness` (97), `SevenTvConsumer` (124),
`EventSubConsumer` (624), `EventSubTopics` (386). `ARCHITECTURE.md` maps the whole app
(Mermaid, 7 diagrams) and includes a "who writes what" mutation map.

## Progress

Updated after the first autonomous pass. Everything below is committed and green at 1084
tests unless noted.

- **Phase 0 (rules and baseline): done.** `docs/ARCHITECTURE_RULES.md`,
  `docs/DECISIONS.md`, `docs/BEHAVIOR_CHECKLIST.md`, and
  `test/architecture/architecture_test.dart` (4 rules) landed. The transport leaves were
  decoupled first (connectivity and data-usage moved to `lib/util`, the JOIN limiter to
  `lib/irc`), and the UI-transport allowlist was later removed, so rule 4 now has no
  exceptions.
- **Phase 1 (spikes): done.** Riverpod 3.4.3 confirmed with the leaf-notifier bridge.
  The mutable engine beat copy-on-write 2.65x to 3.77x at 5000 messages, so D2 holds and
  Phase 6 criterion 2 fails. See `docs/SPIKES.md`.
- **Phase 2 (framework introduction): essentially done.** `ProviderScope` plus
  app-scope providers for connectivity, transports, sevenTv, emote manager, badges,
  user store, recent messages, pip, ping, ignore, join budget, chat, session, the
  feature owners (`TwitchAuth`, `AnalyticsService`, `NotificationService`,
  `TtsController`, `ModActions`, `ChatNoticeController`), read-state (selected channel,
  max messages, reply-to, blocked logins, shared-chat mode, chat readiness, macros),
  the chat pipeline (`ChatConnectionManager`), `BroadcastWidgets`, and `CommandHandler`.
  `HomeScreen` reads them and no longer constructs or disposes them. Only the
  UI-adjacent owners (composer, panels, chrome, message builder, emote applier, media
  upload, panel manager, link whitelist, channel notifier) still construct in
  `HomeScreen`.
- **Phase 3 (observation migration): started.** `HomeScreen` observes the
  provider-owned `EmoteManager`, `TwitchAuth`, `ConnectivityService`, and the
  connection-state port through Riverpod tick/state providers with `ref.listen`;
  `EmoteMenuPanelWidget` is a `ConsumerState` that reads `emoteManagerProvider`. Kernel
  leaf notifiers and per-widget controllers stay on the sanctioned `Listenable` path.
  `LinkWhitelist` and the screen-owned channel notifier are not provider-owned and stay.
- **Phase 4 (chat cleanups): done.** `Channel.setHistoryLoaded` and
  `Channel.clearHeldModeration` funnel the two multi-writer states, and
  `retryChannelData` moved to `ChatChannelSetup`. The connection-status wart is fixed by
  keying rows to stable `sys_conn:<state>` ids (and `sys_loading`) instead of matching
  copy; the fold and row count are unchanged, so rendering is identical. Direct child
  writes are gone: `Channel.addLoadingHistory`/`removeLoadingHistory`/`moveConnectedToTop`
  are the kernel verbs. Moderation-copy unification is done (shared formatter used by the
  IRC and EventSub paths).
- **Phase 5 (ring buffer): not started.** Low priority given the mutable benchmark.
- **Phase 6 (kernel re-evaluation): resolved as keep the engine.**
- **This session (durability pass).** Providerized `BroadcastWidgets` and
  `CommandHandler`; added `whisperSystem`/`whisperSent` signals to
  `ChatUiSignals`; added `emoteManagerTickProvider`, `twitchAuthTickProvider`,
  `connectivityTickProvider`, and `connectionStateProvider`; removed the corresponding
  `addListener`/`removeListener` pairs from `HomeScreen` and `EmoteMenuPanelWidget`;
  extended the architecture test to six rules (pipeline imports plus UI constructions);
  updated `ARCHITECTURE.md` and `docs/DECISIONS.md`. 1,084 tests green.
- **Chat pipeline: done (to the UI boundary).** The pipeline is provider-owned
  (`chatPipelineProvider`) and built entirely from providers; `lib/services` cannot
  import `lib/providers`. Outputs route directly to provider owners where the target is
  data-side: `command` to `CommandHandler`, hype/poll/prediction to `BroadcastWidgets`,
  `mention` to `mentionNotifierProvider`, analytics/TTS direct. The manager's mutable
  `onMention`/`onWhisper` fields folded into `ChatSinks`. `ChatUiSignals` has eight
  members (`focusComposer`, `banner`, `joinProgress`, `reconnected`, `whisper`,
  `userEmoteSets`, `whisperSystem`, `whisperSent`), and every one targets a UI owner that
  lives outside the pipeline (composer, notices/`ChannelManager`, mentions panel,
  `EmoteApplier`). The four custom ChangeNotifier bridges collapsed into one
  `ChangeNotifierTick` adaptor. The provider owns construction and teardown; the screen
  owns when to connect (app lifecycle).
  Finishing further means touching those UI owners, which is the next phase, not the
  pipeline.

## Goal

Move the app from hand-rolled wiring to a framework-owned access and lifecycle layer,
so the next phase is additive-friendly and rule-enforced, without replacing the domain
or the hot path. End state: one idiom for construction, scope, disposal, and
observation; the chat engine kept for its atomic ingest and 5000-message target; the
architecture rules written down and machine-checked.

## Non-goals

- No 1:1 dankchat port. Kotlin + Compose + Android does not map to Dart + Flutter, and
  dankchat has its own god objects (`MainFragment` 1,551, `ChatRepository` 920,
  `MainViewModel` 913) and lacks our EventSub scope and dual-socket IRC.
- No global service locator. Providers are scoped and declare their dependencies.
- No event bus. One typed notifier per owner stays.
- No UI redesign. Visuals and layout do not change.
- Not a leak project. A light parallel audit only; the framework does not fix leaks.
- No codegen in this plan. `json_serializable` is a later, separate track.

## Locked decisions

- **D1 Framework: Riverpod.** Chosen for rules, consistency, lifecycle correctness, and
  additive-friendliness, not for fewer lines. `dart analyze`-safe DI with no
  `BuildContext` or locator, `autoDispose` plus `ref.onDispose`, `ProviderContainer`
  overrides in tests, fine-grained `select`. Pin the version; do not float it.
- **D2 Engine: keep the mutable chat kernel.** `Chat -> Channel -> children` is the
  domain state model, not pipeline logic. It provides atomic multi-child ingest
  (`Channel.receive`), one message source of truth, a thread index, and cross-channel
  aggregates. It stays mutable because immutable state costs a copy plus sort per
  message and breaks the 5000-message target. The engine is framework-agnostic and is
  reached through providers.
- **D3 UI: observation migration only.** Widgets stop constructing shared objects and
  stop manual `addListener`/`removeListener` of shared state. Layout, copy, and styling
  are untouched.
- **D4 No fat runtime object.** There is no `ChatRuntime` bundle. App-scope providers
  each produce one thing; screen-scoped (`autoDispose`) providers hold view-only state.
  The provider graph is the hub. This answers the data/UI split: non-UI state is
  app-scope providers, UI state is screen-scope providers.
- **D5 Ring buffer later.** A true O(1) prepend buffer is a `Messages`-internal change
  behind the existing API, in its own phase.
- **D6 Codegen later, separate.**
- **D7 Scope: chat and main architecture.** Emotes, settings, and other feature
  refactors are deferred.
- **D8 Leak audit: light and parallel.** Not a focus, not gating.
- **D9 Rules live in exactly one file.** `docs/ARCHITECTURE_RULES.md` is the single
  source for architecture rules. `AGENTS.md` only points to it and holds operational
  facts. `docs/DECISIONS.md` holds the rationale. The architecture test enforces the
  mechanical subset and names the rule it checks.
- **D10 Kernel migration is optional and post-Phase 3.** It happens only if both
  criteria in Phase 6 hold. It is not scheduled.

## The two rulebooks

Both are consolidated in `docs/ARCHITECTURE_RULES.md`. Summary:

**Hard rules (non-negotiable):**

1. One writer per state. Rows mutate only through `Channel`/`Messages` verbs;
   coordinated multi-child writes go through `Channel` verbs.
2. One direction: `transport -> decode -> kernel -> pipeline -> UI`. Transport leaves
   import nothing upward; screens import no transport.
3. Providers are the only way to obtain shared objects. No `new` of shared services in
   widgets; no globals.
4. `watch` for reactive reads, `read` only for documented imperative one-shots. Builds
   are pure; effects live in lifecycle methods, `ref.listen`, or notifier methods.
5. Every resource-owning provider registers `ref.onDispose`.
6. Small, purpose-named providers. A god provider is a review failure.
7. The architecture test passes.

**Excusable (allowed, with a note):**

1. The chat kernel is a mutable, framework-agnostic exception. It is exposed through a
   provider, and widgets observe its leaf `ValueNotifier`s with `ListenableBuilder` /
   `ValueListenableBuilder`. This is the one sanctioned non-Riverpod observation path,
   chosen over a fragile Riverpod adaptor for correctness and low risk.
2. A small adaptor layer is allowed during the strangler period.
3. Naming and placement can be sorted later. Never move the same state twice.
4. File-size budgets have an allowlist. A growing file is a signal to extract, not a
   hard wall.

## Definition of done

1. `test/architecture/architecture_test.dart` passes: layer direction plus provider
   placement (no transports in screens, no `ref` in the kernel).
2. No widget constructs a shared service or manually listens to or disposes shared
   state.
3. `HomeScreen` constructs nothing shared; it consumes providers and implements UI
   effects only.
4. The mutation map has no multi-writer states.
5. The 5000-message hot path is verified against the baseline (no dropped frames).
6. A fresh session can read `docs/ARCHITECTURE_RULES.md`, `docs/DECISIONS.md`, and
   `ARCHITECTURE.md` and know the rules and the why.
7. Behavior parity on a written checklist: composer and send, channel join and leave,
   moderation, emotes, whispers, account switch, settings.

## Target architecture

Access is providers; there is no runtime object.

- **App-scope (shared, non-UI)**: `twitchApiProvider`, `eventSubServiceProvider`,
  `ircServiceProvider`, `ircReadServiceProvider`, `sevenTvClientProvider`,
  `emoteManagerProvider`, `badgeServiceProvider`, `userStoreProvider`,
  `twitchAuthProvider`, `pingManagerProvider`, `ignoreManagerProvider`,
  `joinBudgetProvider`, `chatProvider` (the kernel), `sessionProvider`, and
  `chatPipelineProvider` (builds and owns `ChatConnectionManager`).
- **Screen-scope (`autoDispose`)**: selection, tab index, panel state, scroll and
  bottom notifiers, tile caches, composer state that is not shared.
- **Kernel bridge**: `channelProvider = Provider.family<Channel, String>` reads
  `chatProvider`. Widgets observe the channel leaf notifiers with Flutter `Listenable`
  builders (excusable rule 1). Kernel mutations never originate in widgets; they go
  through the pipeline owners.

Lifecycle: providers own construction and teardown. `chatPipelineProvider` registers
`ref.onDispose(() => manager.dispose())`; transport and manager disposal ordering moves
out of `HomeScreen.dispose` and into provider teardown.

## Migration surface (how much changes)

- Stays: kernel (1,587 lines, one bridge and a later internal buffer swap),
  `lib/services` domain logic (18,018), transports (3,415), models (828), emotes (350),
  util (720).
- Migrates mechanically: 29 UI files with 39 `addListener`, 12
  `ValueListenableBuilder`, 38 `ListenableBuilder`, 5 `AnimatedBuilder`; `HomeScreen`
  with 46 construction and dispose sites; ~15 service constructions become providers;
  `main.dart` gains `ProviderScope`; test harnesses move to `ProviderContainer`
  overrides as each area is touched.

This is a migration of the access and observation layer, not a rewrite.

## Phases

Execute in order. Each phase ends with `dart analyze lib test` clean and `flutter test`
green, and is shippable. Commit one per phase at the STOP gate, not one per task. Do not
commit unless told.

### Phase 0: rules and baseline

Tasks:

- Add `docs/ARCHITECTURE_RULES.md` (hard rules, excusable rules, both rulebooks).
- Add `docs/DECISIONS.md` (the rationale in the "Why" section below plus current state).
- Add `test/architecture/architecture_test.dart` enforcing layer direction first:
  `lib/irc` and `lib/eventsub` do not import `lib/services` or `lib/chat`; `lib/chat`
  does not import `lib/services` or `lib/widgets`; screens and widgets do not import
  `lib/irc/transport` or `lib/eventsub/transport`. Each assertion names its rule.
- Add a pointer in `AGENTS.md` to `docs/ARCHITECTURE_RULES.md` and `docs/DECISIONS.md`.
  Do not interweave rules into other sections.
- Capture the behavior checklist (Definition of done item 7) for sign-off.

Deliverable: `chore: add architecture rules and baseline`

Acceptance: architecture test green, existing suites green, checklist approved.

### Phase 1: spikes

Time-boxed, no production change required to ship except the scripts and notes.

Spike A (framework fit): migrate one bounded, non-kernel slice (the mod panel or a
settings screen) to Riverpod. Evaluate ergonomics, test setup, rebuild scope, and how
the kernel's leaf notifiers surface. Output: a written verdict.

Spike B (hot path): implement the mutable engine path and an immutable state path that
both do dedup, insert, truncate, thread index, and unread, and benchmark them under a
bursty ingest to 5000 messages with a rebuilding list. Output: frames and allocation
numbers.

Deliverable: `docs: spike results for riverpod and hot path`

Acceptance: Spike A confirms Riverpod plus the leaf-notifier bridge; Spike B confirms
the mutable engine stays. If Spike A fails, fall back to `provider` and record why.

### Phase 2: framework introduction (strangler)

Tasks:

- Add `ProviderScope` in `main.dart`.
- Add app-scope providers for the services and `chatPipelineProvider`, each with
  `ref.onDispose`. Construction moves out of `HomeScreen`; behavior is unchanged.
- `HomeScreen` becomes a consumer of the pipeline provider and keeps only UI effects
  and view-only state.
- Keep `HomeScreen`'s constructor service params only for tests during this phase;
  remove them as tests migrate.

Deliverable: `refactor: add provider scope and pipeline providers`

Acceptance: app runs; `HomeScreen` constructs nothing shared; suites green.

### Phase 3: observation migration

Tasks:

- Widgets observe app state with `ref.watch` and `select`; kernel leaf state uses the
  sanctioned `Listenable` builders.
- Delete manual shared-state `addListener`/`removeListener` and manual shared dispose
  from widgets.
- Add `select` on the message list and other hot paths.
- Verify the 5000-message path against the Phase 1 baseline.

Deliverable: `refactor: migrate widget observation to providers`

Acceptance: no manual shared-state listen or dispose in widgets; suites green; hot path
at or above baseline.

### Phase 4: chat pipeline cleanups

Limited to the chat path.

Tasks:

- Writer consolidation: add `Channel.setHistoryLoaded` and route the four
  `ChannelManager` sites; add `Channel.clearHeldModeration` and route the three
  `clearHeld` sites.
- Connection status wart: stable ids `sys_conn` and `sys_loading`; upsert the single
  connection line by id from `ChatLifecycle`; delete the `_statusTexts` folding in
  `Messages.addSystem`; make `moveConnectedToTop` and `removeLoadingHistory` match by
  id. Rendering is unchanged.
- Move `retryChannelData` from the manager to `ChatChannelSetup`.
- Unify chat-path moderation copy so the system line and the feed entry share one
  formatter (the AD7 item), for the chat path only.

Deliverable: `refactor: consolidate channel mutation and status`

Acceptance: mutation map has no multi-writer states; suites green.

### Phase 5: ring buffer

Tasks:

- Replace `Messages`' backing list with a ring buffer or deque behind the existing API:
  O(1) prepend, O(1) indexed read, O(1) tail removal for truncation. Public API and
  behavior unchanged except timing.
- Keep the dedup id set and the mutation fan-out as they are.

Deliverable: `perf: ring buffer message storage`

Acceptance: suites green; 5000-message benchmark improved or equal.

### Phase 6: optional kernel re-evaluation

Do this only if both hold:

1. The kernel-to-provider bridge feels leaky, or the kernel is an island that makes
   feature work harder.
2. Spike B shows an immutable path within about 10 percent of the mutable engine on the
   5000-message burst.

If both hold, migrate the engine to Riverpod notifiers as its own phase, with the same
tests and a fresh benchmark. If either fails, stop and keep the engine. This door stays
open because the engine is isolated behind one API and one bridge.

### Deferred

- Codegen (`json_serializable`) for models and prefs plumbing.
- Emote refactor.
- Leak audit fixes.
- Every other feature area.

## Why (rationale to keep in docs/DECISIONS.md)

- **Why a framework**: the app is leaving a churn phase and needs rules. A framework
  gives access and lifecycle rules we currently hand-roll and get wrong (manual
  listen/dispose, `late final` init order, composition root in a screen). It is chosen
  for rules, consistency, lifecycle, and additive-friendliness, not for fewer lines and
  not to fix leaks.
- **Why Riverpod**: compile-safe DI without a locator, `autoDispose` plus
  `ref.onDispose`, `ProviderContainer` overrides, `select`. Accepted tradeoff: the
  mutable chat engine needs the one sanctioned bridge.
- **Why keep the engine**: atomic multi-child ingest, one source of truth, thread index,
  cross-channel aggregates, and the 5000-message target. It is the domain model, not
  pipeline logic, so decentralizing logic does not remove it.
- **Why not a fat runtime**: a single object bundling transports, kernel, pipeline, and
  managers is a new god object. Providers give the same ownership without the bundle.
- **Why not a 1:1 dankchat port**: languages and runtimes differ; dankchat has its own
  god objects; a port discards our dual-socket IRC, EventSub scope, and kernel, and does
  not remove the hard decisions.
- **Why not a global locator or bus**: reachability and hidden coupling are the reason
  the app hurt before the extractions. Scoped providers and typed notifiers preserve
  the fix.
- **Why the kernel migration is optional**: consistency is not worth a hot-path
  regression. Decide from the bridge's feel and Spike B's numbers.

## Risks and mitigations

- **Riverpod version churn**: pin the version. Treat upgrades as deliberate projects.
- **Hot-path rebuilds**: use `select` and the leaf `Listenable` builder for the message
  list. Gate on the Phase 1 baseline.
- **Bridge fragility**: the sanctioned leaf-notifier path is deliberately simple. If it
  becomes leaky, that is Phase 6 criterion 1.
- **Strangler drift**: keep `HomeScreen`'s service params until a phase's tests migrate,
  then delete. Do not leave both paths alive past Phase 3.
- **Provider god objects**: hard rule 6, reviewed.
- **Test churn**: migrate harnesses per area, keep suites green every commit.

## Handoff for a fresh context

- Read `AGENTS.md` (operational), `docs/ARCHITECTURE_RULES.md` (rules),
  `docs/DECISIONS.md` (why), and `ARCHITECTURE.md` (map plus mutation map).
- Current state: eight pipeline extractions shipped; `ChatConnectionManager` is a
  composition root and facade; the kernel is the domain engine; tests green at 1082.
  Phases 0 and 1 are done, Phase 2 is partial (services and kernel are provider-owned;
  the pipeline and UI owners are not), Phase 4 is partial. See the Progress section.
- Locked: Riverpod (D1), keep the mutable engine (D2), observation-only UI (D3), no
  runtime bundle (D4), ring buffer later (D5), codegen later (D6), chat and main
  architecture only (D7), light leak audit (D8), one rules file (D9), optional kernel
  re-eval post-Phase 3 (D10).
- Next: finish Phase 2 by moving the chat pipeline and UI-owner construction into
  providers, then Phase 3 observation migration. Do not start Phase 5 before the access
  work lands.

## References

- `AGENTS.md`: operational commands, conventions, test layout.
- `RULES.md`: commit style and subagent rules.
- `ARCHITECTURE.md`: the map, the services table, and the "who writes what" mutation map.
- `REDUCTION.md`: the LOC-reduction findings, which are deferred and separate from this
  plan.
- `~/chatsen` and `~/dankchat`: references for framework usage (provider + bloc; Koin
  plus Flow), not for a port.
