# Localization / i18n

Not yet implemented. No architectural changes required - Flutter l10n is additive and the
codebase's existing patterns (prefs-backed settings state, constructor-injected service
configs) already fit it. Current state: no `intl`, no `flutter_localizations`, no
`l10n.yaml`, no ARB files; `MaterialApp` (main.dart:142,150) has no
`localizationsDelegates`. ~160+ user-facing literals in screens/widgets plus ~50-100 in
services (command usage/error texts, "Connected"/"Disconnected", "Live with X viewers
for Yh Zm", notification titles, loading/error messages) = ~300-400 unique strings.

## L1. Dependency + wiring (small)

- Problem: the app has no localization infrastructure at all, so nothing can be
  translated.
- Solution:
  - Add `flutter_localizations` (SDK) + `intl` to pubspec; create `l10n.yaml` and
    `lib/l10n/app_en.arb` (English is the source locale; other locales start as AI
    translations).
  - Wire `MaterialApp` (both instances in main.dart): `localizationsDelegates:
    AppLocalizations.localizationsDelegates`, `supportedLocales`, and `locale` bound
    to a prefs-backed state field using the existing `_themeMode`/`_setThemeMode`
    pattern (main.dart:103) so the language can switch at runtime.
  - Add a language picker to Settings (prefs key, e.g. `locale`).

## L2. Service access to translations (the one design decision)

- Problem: services build user-facing strings without a BuildContext: `CommandHandler`
  (usage/error texts), `ChatConnectionManager` ("Connected", "Live with X viewers..."),
  `NotificationService` (ping titles), `RecentMessagesService`, `MediaUploader`,
  `foreground_task`. These are composed into system messages rendered in chat, so they
  must be translated at composition time, not at the edge.
- Solution: inject an l10n accessor into services via the existing config-injection
  pattern (`ChatConnectionConfig` already takes ~20 callbacks). A narrow interface,
  e.g. `String Function(String key, {List<Object> args})` (or a `AppLocalizations`
  wrapper), keeps services decoupled from Flutter's localization machinery and is
  trivially testable. Do NOT use a global singleton or leave service strings in
  English.

## L3. String extraction (the big mechanical chunk)

- Problem: ~300-400 hardcoded literals across screens, widgets, and services.
- Solution: replace literals with `AppLocalizations.of(context)!...` keys; use ICU
  placeholders/plurals for dynamic strings ("Live with {viewers} viewers",
  "timed out for {duration}s", "{count} more options"). Order of extraction: settings
  screens -> widgets -> home_screen -> services (via L2).
- Boundary: Twitch's own `system-msg` (sub/raid notices), usernames, emotes, and chat
  text stay untranslated - only app-authored labels translate. Message span/tile
  caches are unaffected (they hold chat content, not labels).

## L4. AI translation workflow + validation (the safety net)

- Problem: AI-generated translations are good for short UI strings but fail
  mechanically on ICU placeholders/plurals (renaming or reordering
  `{placeholders}`), and drift on chat-domain jargon ("emote", "sub", "raid",
  "shoutout", "whispers", "ping") without a glossary.
- Solution:
  - Generate launch locales (de, es, fr, pt, ja recommended; dev/debug screens can
    stay English) with a strict prompt: preserve `{placeholders}` verbatim, keep ARB
    keys and one line per string, obey the glossary.
  - Maintain a glossary of frozen terms: "ErmChat", "emote", "sub", "raid",
    "shoutout", "whispers", "ping", "true dark" - and the intentional placeholder
    strings that must never be translated (e.g. `g;pr[SomgomgAtYou`,
    "glorpKaraoke", foreground_task.dart:67-68).
  - Add a validation test (~50 lines): every ARB parses; every key in `app_en.arb`
    exists in each locale; every `{placeholder}` in the English string exists in the
    translated string (catches the #1 AI failure mode before it ships).
  - Longer translated strings can break layouts (German/CJK) - QA pass per locale;
    RTL languages (ar/he) need a layout pass on the custom tab bar / input row (no
    structural work, Directionality comes from the delegates).

## Verification

`flutter gen-l10n` succeeds; the ARB validation test passes for every locale; app
launches with each locale set; runtime language switch via Settings applies without
restart; services render translated system messages; chat content and Twitch
`system-msg` remain untranslated.

## Post-0.7.5 backlog

Release wrap-up triage, kept short so 0.7.5 can ship and stop.

### ASAP next update

- Emote resilience: bounded retry on fail, low-res placeholder when tier goes
  Low to High, uncapped FPS follows display refresh.
- Perf: image-embed cache bypass plus double linkify, action-message recolor,
  double tokenize, GIF regex hoist, explicit cacheExtent, checker parity by id.
- Visual: border flicker on tab in, tab strip stretch, double Connected on iOS,
  timestamp gutter width, reply colon on empty preview.
- UX consistency: one slider contract, one empty state, one error with Retry,
  welcome copy fix, InkWell audit, More menu Close, macro Save errors.
- Verify own-message send ack if the read socket dies mid-send.

### Near future

- Widget test prune. 84 candidates cataloged across widgets_test plus the five
  smaller widget files. Keep reconnect dedup, tombstone, thread truncation,
  pause hold, swipe hysteresis, JOIN gate. Only prune when tests churn or CI
  gets slow.
- Notification double-init plus stale map, player and sheet controller swaps,
  subscribe-then-part race.
- Short architecture and data flow doc.
- Mod View 52-issue triage plus Points CRUD decision.

### Far future, major reworks only

- Split connection manager and store god objects. Private state with verbs
  only. Single ingest path. Single moderation formatter. Table-driven EventSub.
  The store/pipeline slice is specified in "ChatStore / pipeline split
  (refactor slice 1)" below.
- UI: single tile cache owner, one tile config for main, thread, mentions,
  history. Split mod_view per tab. Single panel shell. Single input borrow
  stack. Stable video slot across layout modes.
- Features: VOD replay, dual-pane, chat search, full l10n, accessibility pass,
  home widget, iOS push, stream battery saver.

### Rejected for right before release (too high scope)

- Android release signing fallback when key.properties is missing.
- English-only declaration plus F-Droid changelog docs.
- Switching-account connecting hint rework.
- Join dialog validation plus progress plus n/50 count.
- Full widget test gutting.
- All god-object splits and structural UI reworks. (Superseded for chat state:
  see "ChatStore / pipeline split (refactor slice 1)" below.)

# ChatStore / pipeline split (refactor slice 1)

Status: LANDED. The split is done; this section is archived and no longer the live spec.

This is the concrete plan for the "Far future" bullet "Split connection manager
and store god objects. Private state with verbs only. Single ingest path." It is
written for an agent with zero context. Read the whole section before touching
any code. Do not start commit 1 until the plan is approved.

Status: FROZEN. Three agent audits have been absorbed into this spec. Do not open
another design round; make the code match this document, and only the user may
change the document.

## Why

`lib/services/chat_store.dart` (1435 lines) is one class owning roughly twenty
unrelated state domains keyed by the channel string, plus a generic event and
notice bus. Because ownership is shared and cleanup is manual, teardown is
incomplete: `forgetChannel` (chat_store.dart:721) misses several collections,
and the rest is cleared in a different file in an order-sensitive sequence
(`channel_manager.dart:482`). Every feature also reaches into the same blob.
The fix is to move per-channel state into a `Channel` object made of small
single-concern classes, keep cross-channel state on a small `Chat` root, and
delete the generic bus in favor of typed notifiers.

Behavior must not change. This is a structural refactor, not a feature.

## Ground rules (non-negotiable)

1. One concern per file and class. Plain nouns. No `Repository`, `Store`,
   `Manager`, `Service`, `Feed`, `Hub`, or `Handler` in the new `lib/chat/` tree.
2. The new data tree (`lib/chat/**`) imports no `package:flutter/material.dart`,
   no `package:flutter/widgets.dart`, no `BuildContext`, and produces no
   user-facing copy. Allowed: `dart:async`, `dart:ui` value types where already
   used (`Color`), and `package:flutter/foundation.dart` for `ValueNotifier`.
3. Each owner exposes typed notifiers for what it changes. Do not add a generic
   event stream, a signal enum, or a notice bus. `ChatStoreEvent`,
   `ChatStoreSignal`, and `ChatNotice` are deleted.
4. No compatibility facade. Do not keep a `ChatStore` that forwards to the new
   classes. Delete the old API and let compile errors list every call site.
   Do not expose raw collections (`Map`, `List`, `Set`) from the new classes.
   Expose verbs and narrow read accessors. A root under construction is allowed
   during the migration: `ChatStore` may hold `Map<String, Channel>` plus the
   not-yet-migrated domains, but it must not re-expose the old collections or a
   compatible old API. It is renamed to `Chat` at the end, not kept as a shim.
5. One atomic verb per mutation. Ingest must do dedup, insert, truncate, and
   thread index in one call so a caller cannot forget a step. Do not split it
   into several public calls that callers must sequence by hand.
6. No child references its parent. `Channel` composes `Messages`, `Threads`,
   `Unread`, `Moderation`, `Points`, and `Info`. Those children never hold a
   `Channel` or `Chat` reference. `Channel.dispose` disposes the children;
   `Chat.remove` disposes the `Channel`.
7. Every collection has an owner and a drop path. New collections are private.
   The only way to remove a channel is `Chat.remove(name)`, which must free all
   per-channel state with no leftover keys anywhere.
8. Behavior compatibility is proven by tests, not by keeping the old API.
9. Format only touched files (`dart format <file1> <file2> ...`), never
   `dart format .`. Keep comments short. No em-dashes.
10. Do not commit unless explicitly told. Follow `AGENTS.md` and `RULES.md`.

## Decisions and intentional deviations

These are deliberate. Do not revert them to the old behavior and do not re-raise
them in review.

- Clock injection. `Messages` takes an injectable `now()`. The old code used
  `DateTime.now()` directly. Injection is required for deterministic tests, so it
  beats a verbatim move.
- Per-channel system id counter. `_nextSystemMessageId` is per `Messages`
  instance, not global. `sys_` ids only need to be unique within a channel.
- `lastSentWireText` leaves the store. It is send-pipeline state (read at
  `chat_ingestion.dart:411`, written by the composer and duplicate-bypass path)
  and lives with `ChatConnectionManager`/composer, not `ChannelInfo`.
- `channelsEmotesResolved` leaves the store. `EmoteManager` already owns
  per-channel emote caches; add `markEmotesResolved(channel)` and
  `emotesResolved(channel)` there.
- Single channel-list owner. `Chat` owns both the `Map<String, Channel>` and the
  ordered `List<String>`. `channels.dart` is deleted. A second ordered owner will
  diverge.
- Single history-merge owner. One helper on `ChannelManager` performs the ignore
  filter, `userStore.addUser`, the `You/were` rewrite, `pingManager.evaluate`,
  and the `rawHistory` overlap check, then calls `channel.receiveHistory`. All
  three paths (`addChannel`, `refetchHistory`, `onReconnected`) call that helper.
  Do not duplicate the checklist per path.
- Bus removal is last. Migrate state first, keep the old bus until every owner is
  in place, then delete it. This keeps signals stable while state moves.
- Span caches stay on `TwitchMessage` (Option A).
- Typed notifiers only, with one exception. `MessageMutations` is a synchronous,
  lossless listener set that emits each mutated message id. A `ValueNotifier`
  coalesces two ids changed in one frame (raid deletes) and a single
  `lastMutatedId` field drops the first of two different ids, both leaving stale
  tiles. It is typed to one concern, not a generic bus.
- Account switch goes through a verb. `Chat` exposes `switchAccount({String? login})`
  that sets the login and clears account-scoped per-channel state. The direct
  `session.login = null` plus `clearAllHeldMessages` at `home_screen.dart:1283-1284`
  becomes that call. Direct writes to `session` fields are forbidden.
- No facade. Compile errors are the migration checklist.

## Target tree

```
lib/chat/
  chat.dart              Chat: registry (map + order), session, cross-channel totals
  mentions.dart          Mentions: the @mentions pseudo buffer + its totals
  channel/
    channel.dart         Channel: composition root, receive verb, dispose
    messages.dart        Messages: buffer, dedup, truncate, system folding
    threads.dart         Threads: reply index, saved/pinned
    unread.dart          Unread: per-channel counts and flags
    moderation.dart      Moderation: held, feed, warnings, bans, suspicious
    points.dart          Points: rewards and redemptions
    info.dart            ChannelInfo: status, broadcasterId, loadFailures, historyLoaded
```

## Ownership map (old to new)

| Old (chat_store.dart) | New |
| --- | --- |
| `channelMessages` (303) | `Channel.messages` |
| `messageKeys` (308) | private inside `Messages` |
| `_messageCounters` (664) | `Messages.version` |
| `_versions` (663) | `ChannelInfo.version` |
| `_channelThreads`, `savedThreadKeys`, `pinnedThreadKeys` (763-773) | `Channel.threads` |
| `channelsWithUnread`, `channelsWithUnreadMentions`, `unreadMentionsPerChannel`, `unreadMentions` (613-653) | `Channel.unread` plus `Chat` totals |
| `heldMessages`, `modActivity`, `channelWarnings`, `channelBans`, `suspiciousUsers` (344-561) | `Channel.moderation` |
| `pointRewards`, `pointRedemptions` (567-610) | `Channel.points` |
| `chatStatus`, `channelUserIds` (311, 628) | `ChannelInfo` |
| `lastSentWireText` (631) | send pipeline (`ChatConnectionManager`/composer), not `ChannelInfo` |
| `channelLoadFailures`, `loadFailedChannels` (315-318) | `ChannelInfo` per channel; `Chat` aggregate notifier rebuilt from channels |
| `historyLoaded` (622) | `ChannelInfo` (drops with the channel) |
| `channelsEmotesResolved` (625) | emote layer (`EmoteManager`), which already owns per-channel emote caches |
| `mentionsBump`, `unreadVersion` (648, 653) | `Chat` aggregate notifiers; each `Channel.unread` also has its own |
| `onLoginApplied` (641) | `Chat` |
| `session` (637) | `Chat.session`, written only through `applyLogin`; direct field writes forbidden |
| `channels` (301) | `Chat` registry, map plus ordered list; `channels.dart` deleted |
| mentions pseudo channel (`mirrorMentions`, 1005) | `Chat.mentions` |
| `events`, `notices`, `ChatStoreEvent`, `ChatStoreSignal`, `ChatNotice` (23-43, 665-684) | deleted, replaced by typed notifiers and injected UI callbacks |
| `formatModActivity`, `formatTermAction` (161-251) | `lib/util/mod_activity_format.dart` (pure functions; their tests move with them) |
| `_lastTruncateAt`, `truncateWithCoalesce` (1266, 1418) | private inside `Messages` |
| `_nextSystemMessageId` (783) | private inside `Messages` |

## Step 0: exhaustive field audit (before commit 1)

The table above is necessary but not always sufficient. Before writing any code,
enumerate every field of `ChatStore` from `main`, including the constructor
arguments (`chat_store.dart:278-292`) and every `ValueNotifier` and stream, and
record three things per field: the new owner, the read accessor call sites use,
and the drop path. If a field has no owner, stop and resolve it here. The
first-class homes the review added are `historyLoaded`, `channelsEmotesResolved`,
`channelLoadFailures`/`loadFailedChannels`, `mentionsBump`, and `unreadVersion`.
Do not leave a field "implied": Phase B deletes `ChatStore` outright, so an
unassigned field becomes a silent leak.

The checklist must cover, at minimum: the constructor arguments (278-292); the
value types `ActiveSession`, `ThreadEntry`, `HeldMessage`, `ModActivityEntry`,
`WarnEntry`, `BanEntry`, `SuspiciousInfo`; `onLoginApplied`; `session`; the
`channels` list plus `kMaxChannels`; the `formatModActivity`/`formatTermAction`
helpers; and every `ValueNotifier`, stream, and public verb. Read verbs count
too: `recentMessagesFromUser`, `warningsFor`/`warnedLatest`,
`banFor`/`suspiciousFor`, `threadFor`/`activeThreads`, `pinThread`/
`unpinChannelThreads`, `decayEvicted`, `mark*`/`updateMessageText`, and the load
failure methods. Phase B deletes the class outright, so a method still imported
by a panel must already have a new home.

## Behavior to preserve (move verbatim, do not "improve" while moving)

The authoritative source is the old code on `main`. Use
`git show main:lib/services/chat_store.dart`.

- Buffer is newest-first; index 0 is newest.
- `ingestMessage` (951-999): dedup by `$channel:$messageId`, mention and unread
  bookkeeping, insert at 0, coalesced truncate, add key, index threads, mirror
  mentions, mark unread, signal.
- `truncateChannel` (1272-1413) five phases: thread grouping, active-thread
  detection, saved and pinned exemptions, per-thread member cap 20, orphan drop,
  rebuild, decay, key removal.
- `truncateWithCoalesce` (1418-1434): 250ms window, hard-cap factor 2.
- `addSystemMessage` (796-900) status folding and id-less 10s dedup;
  `upsertSystemMessage` (906); `removeSystemMessage` (937).
- Thread cap 64 per channel; pinned members 20; saved and pinned exemptions.
- Unread rules stay identical: mention counts only when `hasMention`, not
  history, not selected channel, not own message. Bulk unread only when not
  selected, not history, not system.
- Moderation and points list caps (200 each) and their ordering.
- `mirrorMentions` (1005-1031) dedup and newest-first sort.

## Span cache decision

Keep `cachedSpans` and `cachedBadgeSpans` on `TwitchMessage`
(`lib/models/twitch_message.dart:112-121`) for this slice (Option A). Do not
move them into a separate render-side cache. The cache moves with the message
and is already invalidated by `EmoteManager.version`; a second cache keyed by
message id would reintroduce cross-owner retention, which is the problem being
fixed.

## The ingest verbs (two, both atomic)

`ChatIngestion` stays the decider. It computes intent, then calls one of two
verbs. Policy (ignore/block/phrase filtering, ping evaluation) stays in the
pipeline before the verb. Buffer laws stay inside the verb.

- `Channel.receive(msg, {required int maxMessages, required bool isSelected,
  required String? ownLogin})` returns `bool inserted`, for one live message. It
  runs the children in the order given under receive ordering below.
- `Channel.receiveHistory(batch, rawHistory, {required int maxMessages})` returns
  the list of inserted messages, for a history/backfill batch. It runs
  `messages.mergeHistory` (dedup against the buffer and within the batch,
  terminal newest-first sort, the `History: Not all messages retrieved` gap note,
  one truncate, key add) plus the thread steps in the order below, and suppresses
  unread and mention counting.
- History does not fit the single-message verb: the old
  `mergeHistoryIntoChannel` (`channel_manager.dart:192-295`) filters, rewrites
  self-authored system rows to `You/were`, folds id-less system rows against
  both the buffer and the batch, evaluates pings, bulk-sorts the whole list,
  injects the gap note, then truncates once. Splitting that into per-message
  `receive` calls would lose the terminal sort and the coalesced truncate.
- Pipeline responsibilities that stay outside both verbs: ignore/block/phrase
  filtering, the self-authored `You/were` rewrite, and ping evaluation. Pass the
  already-decided message or batch in.
- Mirroring to `@mentions` is cross-channel and stays in the caller. For live,
  after a successful `receive`, ingestion calls `chat.mentions.add(msg,
  maxMessages)` when the mention rule matches. For history, the caller mirrors
  the mention-tier messages from the inserted list returned by
  `receiveHistory`.
- `ownLogin` is passed in for the live verb. The data layer must not read
  `Chat.session` ambiently inside a verb.
- The own-message path (`chat_ingestion.dart:400-476`) goes through `receive`.
  Delete its hand-rolled insert, truncate, and index calls, and delete the
  duplicate dedup at `chat_ingestion.dart:451-454`; the buffer owns dedup.
- History must not bump unread or mention counts, matching current behavior.

### receive ordering (both verbs)

`Channel.receive` runs, in order: `messages.add` (dedup, insert, coalesced
truncate, returns evicted), `threads.decay(evicted)`, `threads.index([msg])`,
`unread.note(...)`. Notifiers bump inside the children. Returns `inserted`.
The decay step is mandatory or evicted replies leak in the thread index. Every
`messages.add` and `mergeHistory` call must thread the channel's
`TruncateExemptions` (saved roots plus pinned ids), or saved and on-screen
threads silently stop being exempt. Own-message exemption: when
`msg.login == ownLogin`, skip `unread.note` entirely. The old own path never
touched unread, and routing it through `receive` would otherwise dot a
non-selected channel when the user switches tabs between send and echo.

`Channel.receiveHistory` runs, in order: `messages.mergeHistory(prepared,
rawHistory: raw, ...)` (dedup, id-less fold, sort, gap note, one truncate,
returns inserted + evicted), `threads.decay(evicted)`, `threads.index(inserted)`.
Then the caller (history path) mirrors mention-tier inserted rows to
`Chat.mentions`, stamps `isBackfill`, bumps `ChannelInfo.version` (the old
`touchChannel`), and calls `messages.moveConnectedToTop()`.

History caller checklist, owned by one helper on `ChannelManager` (see
Decisions):
- `isIgnored` filter only. History does not apply `isBlocked`, block-phrase
  drops, or `rewriteMessageKeywords`; that is live-only. Do not port them.
- `userStore.addUser` for non-system rows.
- The self-authored `You/were` rewrite.
- `pingManager.evaluate` only when `msg.highlight == null`, and apply only when
  `state.hasMention` (history keeps its mention-only tint; do not use live
  overwrite semantics).
- Gap-note overlap is checked against the raw fetch, passed as `rawHistory`, not
  the filtered batch, and the note's timestamp is the oldest raw-history row, not
  the oldest prepared row.
- `isBackfill` is stamped only on the refetch path, never on initial
  `addChannel`/`loadChannels`.

Bump `ChannelInfo.version` exactly once per merge. When `prepared` is empty the
helper still bumps and still calls `moveConnectedToTop`, so the `Connected` line
is not buried; do not early-return the whole helper. Do not bump again inside
`moveConnectedToTop`.

## Bus removal

The generic bus is replaced by typed notifiers. The UI subscribes to the owner
it renders. Concretely:

- `Messages.version` (`ValueNotifier<int>`): bumped on any list change (new
  message, truncate, clear). Replaces the `newContent` signal for row lists.
- `Messages.mutations` (`MessageMutations`): a synchronous, lossless listener
  set that emits the id of each in-place edit or delete. Replaces
  `messageMutated`. A `ValueNotifier` is forbidden (equal-value coalescing drops
  back-to-back edits of one id), and so is a single `lastMutatedId` field (two
  different ids changed in the same frame would drop the first, leaving a stale
  tile during raid deletes). `emit(null)` means an uncached row changed and
  consumers no-op. The mutation also bumps `Messages.version`, so the row
  rebuilds and its tile is evicted.
- `ChannelInfo.version`: bumped on status or metadata change. Replaces
  `channelTouched` for channel-level re-render.
- `Moderation` and `Points` keep their existing per-concern versions
  (`modFeedVersion`, `modActivityVersion`, `modInboxVersion`,
  `modSettingsVersion`, `heldVersion`, `pointVersion`), now owned by those
  classes.
- Multi-channel aggregates (`Chat` totals, `Mentions`) expose their own
  notifiers.

`HomeScreen._onStoreEvent` (`home_screen.dart:1233-1255`) and `_onStoreNotice`
(`home_screen.dart:1213-1231`) are deleted. Tile-cache eviction and panel
refresh attach to the typed notifiers instead. `HomeScreen` keeps ownership of
`_tileCache` (`home_screen.dart:294`) for this slice; only the subscription
source changes. Settings-triggered re-render is covered under Settings re-render
below.

UI effects: `ChatNotice.info` and `ChatNotice.focusInput` must not be mapped to
`onSystemMessage`. Today `notifyInfo` becomes a transient banner via
`_chatNotice.show` (`home_screen.dart:1227`), and `Login expired` gets a banner
with an `Open Account` action, while `onSystemMessage` instead writes a chat
system line (`home_screen.dart:1473-1489`). Keep the two paths distinct: add a
dedicated banner callback (`onBanner(message, {action})`) to the
`ChatConnectionManager` config, preserving the `Login expired` action, plus a
composer-focus callback for `focusInput`. Grep `notifyInfo`,
`requestComposerFocus`, and `_chatNotice.show` for call sites. Do not overload
`onSystemMessage` and do not add a new bus.

### Signal mapping (the old bus, resolved)

| Old signal | New |
| --- | --- |
| `noteNewMessage` (buffer paths) | `Messages.version++` |
| `touchChannel` (metadata only) | `ChannelInfo.version++` |
| `touchChannel` (content paths) | `Messages.version++` (see Locked resolutions) |
| `messageMutated(id)` | `Messages.version++` + `mutations.emit(id)` |
| `markUserMessagesDeleted` / `markAllMessagesDeleted` | `Messages.version++` + `mutations.emitAll()` |
| `upsertSystem` in place | `Messages.version++` + `mutations.emit(messageId)` |
| `removeSystemMessage` | `Messages.version++` |
| `moveConnectedMessageToTop` | no separate bump; the merge already bumped `ChannelInfo.version` |
| scroll `onNewMessage` | dedicated scroll callback, no buffer signal (see Locked resolutions) |
| moderation mutations | the owner's existing version notifier |
| EventSub sub-success wakeups | `Moderation.version++` (new; see Locked resolutions) |
| points mutations | `Points.version` |

### Subscriber map

Each consumer attaches to the owner it renders, per channel. This replaces the
single `_onStoreEvent` switch (`home_screen.dart:1233-1255`).

- Chat row list (`ChatView`) -> `Messages.version`.
- Tile cache -> `Messages.mutations` for exact-id eviction and
  `MessageMutations.emitAll()` for a whole-channel evict, in addition to
  `Messages.version` for rebuilds.
- Threads panel -> both `Messages.version` and `ChannelInfo.version` (history
  merges and `moveConnected` change rows without a new live message), and it
  calls `syncSavedWithChannel(channel)` on each bump so saved/pinned state cannot
  drift.
- Mentions panel -> its own mentions/whispers buffer notifier. `mirrorMentions`
  must bump that buffer; the source channel's `Messages.version` is not enough.
  Preserve the closed-panel gate equivalent to `_onPanelDataChanged`.
- Search panel -> `Messages.version`.
- Channel chrome/status -> `ChannelInfo.version`.
- Composer cooldown -> a dedicated callback or `ChannelInfo.version` bump on
  cooldown change; assign an owner in Phase B (`_composer.refreshCooldown` at
  `home_screen.dart:1237` currently runs on every bus event).
- Mod panels -> the `Moderation` versions, including the new sub-success bump.
- Points tab -> `Points.version`.
- Tab labels/unread -> `Channel.unread` plus `Chat` aggregates.

Panels currently refreshed by `_onPanelDataChanged` now listen to the typed
notifier of the owner they draw from instead.

### Subscription lifecycle

Per-channel notifiers are created with `Channel` and disposed only by
`Channel.dispose`. The UI attaches when a channel's widgets mount and detaches
in their own `dispose`; it must never hold a reference to a replaced channel.
`Chat.remove(name)` is called after the frame that unmounts those widgets (this
replaces the split sync-mutate plus `addPostFrameCallback` teardown at
`channel_manager.dart:504-541`) and disposes the `Channel` and all children in
one place. Never dispose a notifier while a listener can still be attached.

### Settings re-render

The roughly 15 `touchChannel` call sites are each replaced by
`ChannelInfo.version++` on the affected channel (or `Chat` for account-wide).
Enumerate them in Phase B with `rg "touchChannel"` and convert one by one; no
call site may stay unmapped.

## Locked resolutions (final, frozen)

These close the third audit. No further design rounds; changes require the user.

### touchChannel conversion (24 sites)

`rg touchChannel lib` finds 24 real sites. Split them, do not bulk-convert:
- Metadata only -> `ChannelInfo.version++`: `chat_channel_setup.dart:335`
  (`composeChatStatus`) and settings-driven metadata rerenders.
- Content (buffer rows changed) -> `Messages.version++`: `channel_manager.dart:293`
  (mergeHistory), `:414` (moveConnected), `chat_ingestion.dart:394` (channel
  clear), `chat_connection_manager.dart:1542` (moderation clear),
  `home_screen.dart:1145` (`_sweepBlocked`), and the internal
  `markUserMessagesDeleted` path.
- EventSub subscription-success wakeups
  (`chat_channel_setup.dart:495,567,628,685,742,804`) mutate no list. They must
  bump a new `Moderation.version`, or the Mod View stops updating after the split.
- Scroll path: `channel_stack.dart:190` passes `noteNewMessage` as
  `ChatView.onNewMessage`, fired on scroll flips
  (`chat_view.dart:161,164,169,292`). Do not map this to `Messages.version`; that
  turns scrolling into a buffer mutation. Give it a dedicated scroll callback
  that does only at-bottom/unread bookkeeping.

### Mass deletes

`markUserMessagesDeleted` and `markAllMessagesDeleted` emit one
`MessageMutations.emitAll()`, which consumers translate to a whole-channel tile
evict. Do not emit one id per row. `MessageMutations.emitAll()` is the second
method on the fan-out.

### upsertSystem

`Messages.upsertSystem` bumps `version` and emits the id itself. Callers
(`channel_manager.dart:375-382`) must not also call `noteNewMessage` or remove the
tile manually. Add a test asserting one signal per upsert.

### switchAccount scope

`Chat.switchAccount({String? login})` reuses existing `Channel` objects and clears
account-scoped state only: unread plus mentions, held, moderation, points, and
connection send state (`lastSentWireText`, self-timeout). It keeps messages,
threads, and saved-thread bookmarks. The old `home_screen.dart:1283-1305`
sequence (login null, clear held, ping/emote/block/mention resets) is the
reference; anything outside `Chat` stays a `HomeScreen` side effect invoked by the
same call site.

### Chat.remove scope

`Chat.remove(name)` frees every in-`Channel` child plus the two collections the
old code leaked: `channelLoadFailures`/`loadFailedChannels` and `_lastTruncateAt`
(now per-`Messages`, freed by `Messages.dispose`). Resources outside `Channel`
(tile cache, scroll/at-bottom controllers, search state, page/tab caches,
`channelNotifier`, `userStore`, `emoteManager`, `badgeService`,
`broadcastWidgets`, `streamPlayer`) are released by `ChannelManager.removeChannel`
in this order: same-frame cache clears (`tileCache`, page/tab caches), unmount,
post-frame `Chat.remove`, then controller disposal. Add a generation guard so a
rejoin before the post-frame callback cannot resurrect a `Channel` the callback
is about to dispose. Saved-thread keys are global persisted bookmarks:
`Chat.remove` drops only the per-channel exemption view, never the saved log.

### Step 0 additions

Add to the audit checklist: the constants `now`, `truncateCoalesceWindow`,
`maxHeldPerChannel`, `maxActivityPerChannel`, `maxWarningsPerChannel`,
`_maxTrackedThreadsPerChannel`, `_maxPinnedThreadMembers`, `_liveSystemDedupWindow`,
`_truncateHardCapFactor`, `kMaxChannels`, and the type `ThreadSummary`; the version
notifiers `heldVersion`, `modActivityVersion`, `modFeedVersion`,
`modInboxVersion`, `modSettingsVersion`, `pointVersion`; and the helpers
`removeSystemMessage` and `moveConnectedMessageToTop`.

### Ground-rule exceptions (named)

- Rule 5 (one atomic verb): cross-channel mirroring to `@mentions` is
  deliberately outside the verb.
- Rule 4 (no facade): the in-progress root may hold `Map<String, Channel>` and
  not-yet-migrated domains, but it never re-exposes the old collections or old
  API.

### messages.dart correction (draft)

The drafted `Messages.mergeHistory` takes the gap-note timestamp from `prepared`;
it must take the oldest `rawHistory` row. Fix when code work resumes and add a
test with an ignored oldest row. Also add `MessageMutations.emitAll()` for the
mass-delete path.

## Execution workflow (chosen path, supersedes staged commits)

This build is a greenfield draft, a nuke, a test port, then a review. The old
code on `main` (and the up-to-date copy at `~/ermchat`) is the behavior
reference. `git show main:<path>` also works.

- Phase A, draft. Build `lib/chat/**` from the old code, moving laws verbatim
  (see Behavior to preserve). Nothing is wired. The tree does not have to
  compile as a whole during this phase.
- Phase B, nuke and wire, in vertical slices. Do one concern at a time:
  messages + threads + unread, then info, then moderation, then points. Keep the
  old bus until all state owners are migrated, then remove the bus as the last
  slice. In each slice, delete that concern's old code and update its call sites
  to the new verbs, ending with a clean `flutter analyze`. Do not big-bang
  delete; keep the red window short. No facade or compatibility shim.
- Phase C, tests. Another agent ports the old tests to `test/chat/` and gets
  them passing, then deletes the old test files. See Tests.
- Phase D, review. Another agent reviews the draft against the old behavior and
  the ground rules.

The design sections above (target tree, ownership map, Step 0, behavior, verbs,
bus removal) are the spec for Phase A and B.

## Migration surface (files importing chat_store.dart)

`lib/emotes/emote_applier.dart`, `lib/sheets/user_sheet.dart`,
`lib/panels/mentions.dart`, `lib/panels/mod_panel.dart`,
`lib/panels/search.dart`, `lib/panels/threads.dart`,
`lib/chrome/channel_stack.dart`, `lib/chrome/stream_layout.dart`,
`lib/chrome/home_app_bar.dart`, `lib/screens/home_screen.dart`,
`lib/widgets/mod_view.dart`, `lib/channels/channel_manager.dart`,
`lib/widgets/user_profile_sheet.dart`, `lib/composer/composer_controller.dart`,
`lib/composer/composer_bar.dart`, `lib/services/chat_channel_setup.dart`,
`lib/services/chat_ingestion.dart`, `lib/services/chat_connection_manager.dart`,
plus tests. This list is a starting point only. Verify with
`rg "chat_store|touchChannel|noteNewMessage|messageMutated|versionNotifier|messageCountNotifier" lib test`,
because several call sites reach the store's signal verbs without importing the
file directly.

## Tests (Phase C, ported by another agent)

- Write `test/chat/` tests by porting the old tests. Do not invent expectations
  that the new code happens to satisfy. The old tests encode the behavior we
  must keep: truncate phases, thread cap, unread rules for the four cases (own,
  history, selected, mention), system folding, moderation caps, points ordering.
- Gate: `flutter test test/chat/` passes, then the full `flutter test` passes
  after the old test files are deleted.
- Delete the old test files as the ports land. Final state has none.
- Do not chase coverage. One test per law.

## Verification

- Phase B end: `flutter analyze` clean.
- Phase C end: `flutter test test/chat/` green, then full `flutter test` green
  with the old test files deleted.
- Run the app on two or three busy channels: buffer stays at the configured cap,
  unread dots and mention counts behave, replies index, leaving a channel frees
  everything (rejoin starts clean), emote rendering and in-place deletes still
  work.
- Specifically verify the laws most likely to regress: thread cap 64 per channel,
  saved/pinned truncation exemptions, gap-note overlap when an ignored row
  overlaps the buffer, backfill grey-out, and raid-style bursts of deletes all
  evicting their tiles (the lossless mutation fan-out).
- Leak check on leave and rejoin: no growth in `Chat.channels` count, no stale
  per-channel state after `Chat.remove`.
- No new `Map`, `List`, or `Set` without an owner and a drop path.

## References

- Old code: `git show main:<path>` (for example
  `git show main:lib/services/chat_store.dart`). `main` is stable; this refactor
  happens on a separate branch.
- `~/dankchat` is an Android Kotlin app used only as a structural pattern
  reference (feature folders, small channel-keyed owners, typed flows, explicit
  per-owner cleanup). It is local to one machine and must not be vendored or
  copied into the repo.
- `AGENTS.md` and `RULES.md` still apply: short comments, no em-dashes, minimal
  diffs, no commits unless told.

## Explicitly out of scope

- Emotes, images, tile-cache ownership, panels redesign, auth, mod view
  structure.
- Renaming existing pipeline classes beyond what the new vocabulary requires.
- Any behavior change to parsing, filtering rules, or IRC transport.
