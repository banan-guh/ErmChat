# Architecture rules

This file is the single source of architecture rules for ermchat. It is the one place
the rules live: AGENTS.md points here and keeps only operational facts, and
docs/DECISIONS.md holds the rationale behind them. The architecture test enforces the
mechanical subset of these rules, layer direction plus provider placement, and each
assertion names the rule it checks so a failure points at the rule it breaks. What the
test cannot see (ownership, purity, provider size) is enforced in review.

## Target dependency direction

```
transport / codec   lib/irc, lib/eventsub/transport, lib/eventsub/decode
        |
      kernel         lib/chat
        |
     pipeline        lib/services
        |
        UI           lib/widgets, lib/screens, lib/chrome, lib/composer,
                     lib/panels, lib/sheets
shared leaves        lib/models, lib/util, lib/client
```

- Transport and codec turn bytes and frames into typed events. They import their own
  leaves and nothing upward.
- The kernel (`lib/chat`) is the domain state model. It is framework-agnostic and does
  not import `lib/services` or any UI directory.
- Pipeline (`lib/services`) reads transports and decoders, applies logic, and mutates
  the kernel through its verbs. It does not import UI.
- UI reads kernel state through providers and the sanctioned `Listenable` builders and
  never imports transport directly.
- Shared leaves (`lib/models`, `lib/util`, `lib/client`) are importable from every layer
  and import nothing upward themselves.
- Providers (`lib/providers`) are the composition root. They construct the app-scope
  owners, register teardown, bridge provider-owned `ChangeNotifier`s to Riverpod
  observation, and wire the pipeline. Pipeline (`lib/services`) must not import them;
  the architecture test enforces this direction.

## Hard rules (non-negotiable)

1. **One writer per state.** Rows mutate only through `Channel`/`Messages` verbs, and
   coordinated multi-child writes go through `Channel` verbs such as `receive` and
   `receiveHistory`. Do: route ingest through `Channel.receive`. Do not: let two owners
   write the same field, or have a widget or pipeline component assign child internals.
   Row-scoped moderation edits are the one documented `Messages` exception.

2. **One direction of dependency.** Transport leaves import nothing upward, and screens
   import no transport. Do: a decoder exposes a typed callback consumed by pipeline.
   Do not: import `lib/services` from `lib/chat`, or `lib/irc/transport` from a screen.

3. **Providers are the only way to obtain shared objects.** Do: read a shared service
   with `ref.watch(...)` or `ref.read(...)`. Do not: construct a shared service in a
   widget, and do not keep a global or singleton handle to shared state.

4. **`watch` for reactive reads, `read` only for documented imperative one-shots.**
   Builds are pure, and effects live in lifecycle methods, `ref.listen`, or notifier
   methods. Do: `ref.watch(twitchAuthProvider)` to rebuild on change. Do not: call
   `ref.read` to react to state, or start a request or subscription from `build`.

5. **Every resource-owning provider registers `ref.onDispose`.** Do:
   `chatPipelineProvider` registers `ref.onDispose(() => manager.dispose())`. Do not:
   leave sockets, timers, streams, or notifiers alive when their provider is torn down.

6. **Small, purpose-named providers.** A provider produces one thing with a name that
   says what that thing is. A god provider that bundles transports, kernel, pipeline,
   and managers is a review failure.

7. **The architecture test passes.** `test/architecture/architecture_test.dart` stays
   green, and new violations are fixed at the source, not by weakening the test.

8. **Owner ports, not parent state.** An extracted owner exposes typed
   notifiers/signals for what it produces and takes one explicit, minimal interface
   for what it needs. Do: pass typed callbacks, a signal sink, or a small host
   interface. Do not: store the parent `State`, take `host: this`, or otherwise reach
   back into the screen. Providers (`lib/providers`) are the composition root;
   `lib/services` never imports `lib/providers`, and the kernel's `Listenable` leaves
   remain the one sanctioned non-Riverpod observation exception.

## Excusable rules (allowed, with a note)

1. **The mutable kernel is the one sanctioned non-Riverpod exception.** It is exposed
   through a provider, and widgets observe its leaf `ValueNotifier`s with
   `ListenableBuilder` / `ValueListenableBuilder`. This is the single sanctioned
   non-Riverpod observation path, chosen over a fragile Riverpod adaptor for correctness
   and low risk. Kernel mutations still never originate in widgets.

2. **A small adaptor layer is allowed during the strangler period.** A thin bridge may
   translate between legacy hand-rolled wiring and providers while an area migrates.
   It is temporary, and it must not become a second writer or a second source of truth.

3. **Naming and placement can be sorted later.** Move a piece of state once, when its
   area migrates. Never move the same state twice for tidiness.

4. **File-size budgets have an allowlist.** A growing file is a signal to extract, not a
   hard wall. Exceeding a budget needs a note, not an automatic split.

## How to apply

- Mechanical rules are enforced by the test. Layer direction (rule 2) and provider
  placement (no transports in screens, no `ref` in the kernel) live in
  `test/architecture/architecture_test.dart`, and each assertion names its rule.
- Ownership, purity, and provider size are review rules. Rules 1 and 3 through 6 are
  caught by reading the diff, not by the test.
- To break a rule, document it in `docs/DECISIONS.md` with the decision, the reason, and
  the scope. An undocumented violation is a bug. If the violation is temporary, name the
  phase that removes it.
