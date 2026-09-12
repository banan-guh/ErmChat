# Spikes

Results of the Phase 1 spikes from PLAN.md. These are evidence records, not rules. They
back the locked decisions in `docs/DECISIONS.md`.

## Spike A: Riverpod fit and the kernel bridge

Question: does `flutter_riverpod` fit this app's DI, lifecycle, and observation needs,
including the planned bridge for the mutable chat kernel whose leaf state is exposed as
Flutter `ValueNotifier`s?

Method: `test/spikes/riverpod_fit_test.dart`, a deterministic widget test (8 tests) with
rebuild counters and disposal flags. Added `flutter_riverpod: ^3.4.3` in this phase.

Result: confirmed. The planned shape works.

- Provider types used: `Provider<T>`, `NotifierProvider<N, T>(N.new)`, and
  `Provider.autoDispose<T>(...)`.
- Overrides: `ProviderContainer(overrides: [p.overrideWith((ref) => fake)])` and
  `p.overrideWithValue(fake)`, the same list on `ProviderScope`. There is no
  `overrideWithProvider` in 3.x.
- `select`: `ref.watch(snapshotProvider.select((s) => s.count))` holds rebuilds at 1 while
  an unrelated field changes, then rebuilds to 2 when the selected field changes.
- Kernel bridge: a provider returns a `ValueNotifier<int>` (stand-in for
  `Messages.version`); `ValueListenableBuilder` rebuilds on `value++` with zero Riverpod
  rebuilds. Riverpod supplies the object, Flutter binds to the leaf notifier. This is the
  sanctioned exception and it is cheap.
- Disposal: `Provider.autoDispose` plus `ref.onDispose` runs the callback exactly once
  when the last listener leaves.
- Test setup: a plain `ProviderContainer` drives a provider with no widget binding.

Gotchas and their implications for Phases 2 and 3:

1. Legacy split. `StateProvider`, `StateNotifierProvider`, and `ChangeNotifierProvider`
   moved to `package:flutter_riverpod/legacy.dart`. Existing `ChangeNotifier` services
   (`EmoteManager`, the relocated `ConnectivityService`, auth notifiers) can be wrapped
   with `ChangeNotifierProvider` so `ref.watch`/`ref.listen` fire, and that import is
   required. `ref.listen` on such a provider receives the same instance as `previous` and
   `next`, so read the field (`next.ticks`) rather than comparing instances.
2. `autoDispose` is asynchronous. Disposal is scheduled for the end of the next event
   loop, so tests must `await container.pump()` before asserting. Last-widget-unmount does
   not free a resource synchronously.
3. `WidgetRef.listen` returns `void`. Use `ref.listenManual(...)` when a widget needs a
   cancellable subscription.
4. `select` adds nothing when the provider just returns the kernel's existing
   `ValueNotifier`; watch the notifier directly there. `select` matters for
   provider-owned derived state.
5. A non-`autoDispose` `Provider` is cached for the container lifetime, which fits
   long-lived kernel objects. Reserve `autoDispose` for per-scope resources.

## Spike B: mutable kernel versus immutable state at 5000 messages

Question: should the mutable chat kernel stay, or is an immutable state model close
enough on the 5000-message hot path? Decision rule: the mutable engine stays unless the
immutable path is within about 10 percent.

Method: `tool/spikes/hot_path_bench.dart`, run with `dart run`. It mirrors the real
kernel laws:

- Newest-first order, `_items.insert(0, msg)` (`lib/chat/channel/messages.dart:121`).
- Dedup via `_seenIds` (`messages.dart:117-122`).
- Cap 500 (`lib/util/constants.dart:34`), with the coalesced truncation cadence
  (`truncateCoalesceWindow` 250ms, burst expands past `maxMessages * 2`,
  `messages.dart:50,565-571`). Truncation is simplified to tail-trim; the real pass is
  thread-aware retention (`messages.dart:427-554`) and is the same per-pass O(n).
- Thread index root to replies, created lazily and capped at 64 with LRU decay
  (`lib/chat/channel/threads.dart:38,112-136,175-193`).
- Unread and mention counts (`lib/chat/channel/unread.dart:20-26`), matching
  `Channel.receive` order (`lib/chat/channel/channel.dart:57-102`).

The immutable model is copy-on-write: each insert allocates `[msg, ...items]`, copies the
id set, and deep-copies the thread map and reply lists. This is the representative pure
Dart immutable rewrite because `dart:core` ships no persistent collections. A second
variant keeps the dedup set as a shared mutable index, separating rehash cost from buffer
and thread copying. A hand-rolled persistent vector or HAMT could narrow the gap and was
not measured.

Workload: 5000 messages, 25 bursts of 200, 5 percent duplicates, 10 percent replies,
11 measured iterations after 2 warmups. Ingest plus a read of the recent 100 and a thread
lookup.

```
store                       median ms   p90 ms    us/msg
---------------------------------------------------------
mutable                          6.62     7.39      1.32
immutable COW (all)             24.94    26.79      4.99
immutable COW (seen shared)     17.57    18.05      3.51

ratio immutable/mutable (median):    3.77x
ratio shared-seen/mutable (median):  2.65x
```

RSS deltas were noise, so allocation is not measured.

Verdict: the mutable engine stays. The cheapest immutable path is 2.65x to 3.77x slower,
well outside the 10 percent bar. This confirms D2 and already fails Phase 6 criterion 2,
so the optional kernel migration is not triggered. It would only reopen if a persistent
collection approach changed the math, which is out of scope.

Caveats: this measures copy-on-write, not a HAMT kernel. Truncation is simplified.
Timings are JIT `dart run` on one isolate, not mobile AOT, with no GC control.

## Consequences for the plan

- Phase 2 proceeds with Riverpod 3.x and the leaf-notifier bridge as designed.
- Phase 3 uses `select` for provider-owned state, and direct `Listenable` builders for
  kernel leaves.
- Phase 6 is effectively decided: keep the engine. No further kernel migration work is
  scheduled.
