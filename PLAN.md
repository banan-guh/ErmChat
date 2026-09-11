# EventSub reorg (realtime source slice 2)

Status: FROZEN. Make the code match this document; only the user changes it. Do not
open another design round.

This is the concrete plan to give Twitch EventSub one home, make its event model fail
hard instead of silent, and add the tests that do not exist today. It is written for an
implementing agent with zero context. Read the whole document before touching code. Do
not start a group until the previous group is green and reported.

Stages 1 through 3 are owner extraction and pure moves. Stage 4 is the only model
change. The rendered output must not change in any stage.

## Why

EventSub is one subsystem with three owners:

- **Protocol**: `lib/services/twitch_eventsub.dart` (1080) fuses the socket, session
  handshake, keepalive, the JSON frame, the `subscription_type` switch, 14 typed
  streams, and the event classes.
- **Subscription lifecycle**: `lib/services/chat_channel_setup.dart` holds 14
  active/skip sets, seven near-identical `_subscribeX` methods, the resubscribe path,
  and the seven gate predicates.
- **Consumption**: `lib/services/chat_connection_manager.dart:1530-2052` applies the
  typed events to `Chat`/`Moderation`/`Points` and emits system lines.

The seams between these owners cause the known hazards: session-scoped active sets
versus account-scoped skip sets reset in a different object than the consumer,
`isModerationActive` arbitration split from the code it gates, EventSub listeners bound
with `??=` so they never rebind, `_channelUserIds` never cleared, and seven subscribe
methods with divergent success rules and no tests.

EventSub itself is receive-only. Subscriptions go out over Helix
(`TwitchApi.createEventSubSubscription`), notifications come in over the socket.
Actions (ban, timeout, delete, warn, raid, poll, prediction, shield, shoutout) are
Helix REST and already have a single owner, `ModActions`
(`lib/services/mod_actions.dart:30`). They stay there. This plan does not move actions,
and does not fold them into EventSub.

The event model is also stringly-typed. `ModerationEvent.action`
(`twitch_eventsub.dart:16`) and ten `String kind` fields
(`:75,92,109,128,155,178,191,204,237,261`) are switched on string literals behind a
silent `default:`. A typo or a new Twitch action is a runtime no-op. Enums turn that
into a compile error.

## Ground rules (non-negotiable)

1. `lib/eventsub/transport/**` imports no `lib/chat/**`, no `lib/models/**`, no
   `lib/client/session.dart`, and no `lib/eventsub/decode/**`. It emits frames and
   connection events only.
2. `lib/eventsub/decode/**` may import `lib/models/**`, `lib/client/session.dart`, and
   `lib/util/**`.
3. `lib/eventsub/topics.dart` may import `TwitchApi`, `TwitchAuth`, `Session`, `Chat`,
   the transport, and `lib/util/**` (it logs with `logDebug`).
4. `lib/services/eventsub_consumer.dart` may import `Chat`, `Session`,
   `EventSubTopics`, the decoder, and `lib/util/**`.
5. No compatibility facade or barrel. `lib/services/twitch_eventsub.dart` is deleted at
   the end of Stage 1. Update every call site; compile errors are the checklist.
6. Stages 1 through 3 are pure moves or pure owner extraction. Do not improve behavior
   while relocating it. Stage 4 is the only model change.
7. Format only touched files (`dart format <file> ...`), never `dart format .`. Short
   present-tense comments. No em-dashes. Do not commit unless told. Follow `AGENTS.md`
   and `RULES.md`.

## Target tree

```
lib/eventsub/
  transport/
    events.dart      EventSubStatus
    connection.dart  EventSubService (socket, reconnect, keepalive, session,
                     connectivity) -> onNotification + onStatus + sessionId
  decode/
    events.dart      all typed event classes
    decoder.dart     EventSubDecoder -> 14 typed streams, setChannelMapping,
                     feed, dispose
  topics.dart        EventSubTopics (14 sets, subscribe/resubscribe/reset/
                     forget, 7 gate predicates, isBroadcaster)

lib/services/
  eventsub_consumer.dart   EventSubConsumer (typed events -> Chat/UI)
```

`EventSubConsumer` stays in `lib/services/` because it mutates the chat kernel, exactly
like `ChatIngestion` for IRC. `EventSubTopics` lives under `lib/eventsub/` because it is
the EventSub client surface (subscribe/resubscribe), even though it talks to Helix and
`Session`. The transport class keeps the name `EventSubService`; renaming it is out of
scope.

## Ownership map (old to new)

| Old symbol | Old site | New home |
| --- | --- | --- |
| event classes | `twitch_eventsub.dart:14-285` | `eventsub/decode/events.dart` |
| `EventSubStatus` | `twitch_eventsub.dart:1080` | `eventsub/transport/events.dart` |
| typed controllers + getters | `twitch_eventsub.dart:312-351,373-392` | `eventsub/decode/decoder.dart` |
| `isConnected`/`sessionId`/`isStale`/`forceReconnect` | `twitch_eventsub.dart:353-369` | `eventsub/transport/connection.dart` |
| `setChannelMapping`/`_channelFromPayload` | `twitch_eventsub.dart:394-405` | `eventsub/decode/decoder.dart` |
| `waitForSession` | `twitch_eventsub.dart:407-411` | `eventsub/transport/connection.dart` |
| `connect`/`_scheduleReconnect`/`_safeComplete`/`_waitForReady` | `twitch_eventsub.dart:413-514` | `eventsub/transport/connection.dart` |
| `_handleMessage` (session arms, notification emit) | `twitch_eventsub.dart:516-537` | `eventsub/transport/connection.dart` |
| `_onWelcome`/`_handleReconnect`/`_resetKeepalive` | `twitch_eventsub.dart:539-573` | `eventsub/transport/connection.dart` |
| `_onNotification` + 14 builders | `twitch_eventsub.dart:577-1010` | `eventsub/decode/decoder.dart` |
| `_ensureConnectivityListener`/`disconnect`/`handleRawMessage`/`emitConnected`/`dispose` | `twitch_eventsub.dart:1012-1077` | `eventsub/transport/connection.dart` |
| subscription sets | `chat_channel_setup.dart:88-126` | `eventsub/topics.dart` |
| gate predicates + `isBroadcaster` | `chat_channel_setup.dart:157-187` | `eventsub/topics.dart` |
| `clearSessionState`/`resetAccountScope` | `chat_channel_setup.dart:205-226` | `eventsub/topics.dart` |
| `forgetChannel` (EventSub half) | `chat_channel_setup.dart:230-237` | `eventsub/topics.dart` |
| 7 `_subscribeX` | `chat_channel_setup.dart:464-880` | `eventsub/topics.dart` |
| `resubscribeEventSubChannels` | `chat_channel_setup.dart:885-913` | `eventsub/topics.dart` |
| 11 event handlers | `chat_connection_manager.dart:1533-2052` | `eventsub_consumer.dart` |
| widget listeners | `chat_connection_manager.dart:1500-1514` | `eventsub_consumer.dart` |
| EventSub subscription fields | `chat_connection_manager.dart:361-381` | `eventsub_consumer.dart` |
| public delegators `isModerationActive`/`isAutomodActive`/`isBroadcaster` | `chat_connection_manager.dart:534-542` | re-point at `EventSubTopics` |

## The seam

- `EventSubService` parses each JSON frame, consumes
  `session_welcome`/`session_reconnect`/`revocation`, and emits every `notification`
  frame on `Stream<Map<String, dynamic>> get onNotification`. It keeps `connect`,
  `disconnect`, `forceReconnect`, `isConnected`, `isStale`, `sessionId`,
  `waitForSession`, `onStatus`, `handleRawMessage`, `emitConnected`, `dispose`.
- `EventSubDecoder(Stream<Map<String, dynamic>> source)` owns the 14 controllers,
  `setChannelMapping`, `_channelFromPayload`, the `subscription_type` switch, the
  builders, a `@visibleForTesting void feed(Map<String, dynamic> frame)`, and
  `dispose`. The `subscription_type` router stays a string switch: it is protocol
  dispatch, not a domain enum. An unrecognized type is dropped, and A2 adds the one
  permitted non-move line, a `logDebug` naming the type so a silent miss is visible.
- `EventSubTopics` owns the subscription lifecycle: `subscribeChannel(channel,
  channelUserId)`, `resubscribeEventSubChannels(channels)`, `clearSessionState`,
  `resetAccountScope`, `forgetChannel`, the seven gate predicates, and
  `isBroadcaster`. It reads `eventSub.sessionId` for the handshake wait.
- `EventSubConsumer.attach(EventSubDecoder)` subscribes the 14 streams and returns the
  subscriptions; `dispose()` cancels them. The manager constructs it and re-points
  `statusSub` at `eventSub.onStatus` only.
- `ChatChannelSetup` shrinks to joins, Helix/emote/badge/7TV resolution, and chat-status
  composition. `subscribeChannel` calls `eventSubTopics.subscribeChannel`;
  `forgetChannel` splits into `eventSubTopics.forgetChannel` plus the existing 7TV
  cleanup.
- The manager keeps transport, lifecycle, readiness, send gates, ingestion, and the
  public delegators, which re-point at `EventSubTopics`. UI call sites do not change.

Construction and wiring: the manager constructs `eventSubTopics` (it needs `TwitchApi`,
`TwitchAuth`, `Session`, `Chat`, and the transport) and `eventSubDecoder` on
`eventSub.onNotification`. It passes the same `eventSubTopics` instance to
`ChatChannelSetup` and to `EventSubConsumer`, and the decoder to the consumer.
`ChatChannelSetup` owns no EventSub state after Stage 2. The consumer attaches in
`_setupSubscriptions`.

Ordering is safe: `_setupSubscriptions()` runs at `chat_connection_manager.dart:881`
before `eventSub.connect()` at `:1110`, and it builds the decoder, so decode is
listening first.

Dispose order inside the manager: `eventSubConsumer.dispose()` (cancel the 14 stream
subscriptions), then `eventSubDecoder.dispose()` (cancel its `onNotification`
subscription). The transport is disposed later by `HomeScreen` (`:1508`), after the
manager (`:1500`), so the decoder unsubscribes before the transport closes its
controllers. Pin this now: A2 adds only `eventSubDecoder.dispose()`, and C2 inserts the
consumer dispose ahead of it.

## Stages and grouping

Execute the groups in order. Each group ends with `dart analyze lib test` clean and
`flutter test` green, and is committed separately only when told.

Commit one per group, at the STOP gate, not one per stage. Tests ride in their group's
commit.

| Group | Commit |
| --- | --- |
| plan doc | `chore: add eventsub reorg plan` |
| A (Stages A1+A2) | `refactor: split eventsub transport decode` |
| B (Stages B1+B2+B3) | `refactor: extract eventsub topics` |
| C1+C2 | `refactor: extract eventsub consumer` |
| C3 | `refactor: enum eventsub event fields` |

C3 stays its own commit because it is the only model change; everything else is
structural.

### Group A: protocol home (Stage 1)

Pure structure. Execute first, then STOP.

- **A1 (pure move).** Create `eventsub/decode/events.dart` and
  `eventsub/transport/events.dart`; move the classes verbatim; delete them from
  `twitch_eventsub.dart`; update importers. No behavior change.
- **A2 (the seam).** Add `onNotification`; create `EventSubDecoder`; strip and move the
  transport to `eventsub/transport/connection.dart`; delete `twitch_eventsub.dart`.
  Manager builds `eventSubDecoder` and re-points `:1480-1514` from `eventSub.onX` to
  `eventSubDecoder.onX`; `statusSub` stays on the transport. `ChatChannelSetup` gets
  `eventSubDecoder` and calls it at `:374`. Add `eventSubDecoder.dispose()` at manager
  `:444`. Topics and consumption stay where they are.
- **Gate**: `dart analyze lib test` clean and `flutter test` green.

**STOP after A2.** Report the diff and the test count. Do not start Group B until told.

### Group B: subscription home (Stage 2)

- **B1 (characterization tests).** Add `test/unit/eventsub_topics_test.dart`, driven
  through a `TwitchApi` fake: success sets the active set, 403 sets the skip set, each
  family's success rule holds (moderation single, automod all, feed/inbox/trust/points
  any, widgets all), the broadcaster gate holds for points/widgets, and clear vs reset
  vs forget touch the right sets.
- **B2 (extract).** Create `EventSubTopics` and move the sets, the seven `_subscribeX`,
  `resubscribeEventSubChannels`, the resets, the EventSub half of `forgetChannel`, the
  predicates, and `isBroadcaster`, verbatim. `ChatChannelSetup.subscribeChannel` calls
  `eventSubTopics.subscribeChannel`. The manager calls `eventSubTopics` for
  `clearSessionState` (`:901,1100,1261`), `resetAccountScope` (`:1108,1158`), and
  `resubscribeEventSubChannels` (`:903`).
- **B3 (collapse).** Replace the seven methods with a table of `(types, versions,
  conditionBuilder, successRule, skipSet, activeSet)`. Each family keeps its exact
  current success rule. Add tests for any rule the B1 tests do not already pin.
- **Gate**: `dart analyze lib test` clean, `flutter test` green, and the new topics
  tests green.

**STOP after B3.** Report. Do not start Group C until told.

### Group C: consumption home and fail-hard model (Stages 3 and 4)

- **C1 (characterization tests).** Add `test/unit/eventsub_consumer_test.dart`, driving
  `EventSubDecoder.feed` and asserting `Chat` effects and system lines for
  delete/clear, ban/timeout self-gate, feed gating per predicate, inbox/trust, points
  reward merge and redemption resolve, and automod hold/resolve.
- **C2 (extract).** Create `EventSubConsumer` and move the 11 handlers, the widget
  listeners, and the subscription fields verbatim. It owns `attach(EventSubDecoder)` and
  `dispose()`. The manager keeps construction, `attach`, `dispose`, and the public
  delegators. This also removes the `??=` rebind model for EventSub.
- **C3 (fail hard).** Replace `ModerationEvent.action` and the ten `kind` strings with
  enums mapped once in the decoder. Each enum carries an `unknown` arm that preserves
  the raw wire string for forward compatibility. Make the consumer switches exhaustive
  and delete the silent `default:` fallthrough; the `unknown` arm handles the rest
  explicitly. Convert back to the wire string at the consumer so `ModActivityEntry` and
  the UI stay unchanged.
- **Gate**: `dart analyze lib test` clean, `flutter test` green, and the new consumer
  tests green.

**STOP after C2.** Report. Do C3 as its own reviewed commit only when told.

## Behavior to preserve (move verbatim)

- Session: `session_welcome` sets `sessionId`, completes the waiter, reads
  `keepalive_timeout_seconds`, resets keepalive, emits `connected`, resets the reconnect
  attempt (`twitch_eventsub.dart:539-548`). `session_reconnect` reconnects to
  `reconnect_url` (`:550-562`). `revocation` logs only (`:529-530`). Keepalive resets on
  every frame and fires at 1.5x (`:565-573`).
- Transport: backoff `min(2^(n-1), 30)` plus jitter, capped at 8 attempts and gated on
  connectivity (`:464-482`). `_handleMessage` order: read `message_type`, route,
  then `_resetKeepalive` (`:516-537`).
- Decode: `_onNotification` routing on `subscription_type`, including the
  `channel.hype_train.`/`channel.poll.`/`channel.prediction.` prefixes and the
  `channel.suspicious_user.*`, `channel.channel_points_custom_reward*`, and
  `automod.message.*` families (`:577-646`).
- Builders: all field fallbacks and defaults exactly as written, including the automod
  v1/v2 message and category shape (`:648-677`), the timeout duration clamp
  (`:946-955`), `shared_chat_` action unwrap (`:912-916`), and the term/unban nesting
  (`:966-979`).
- Consumer: all system-line copy, the self-timeout gate arm and clear
  (`chat_connection_manager.dart:1619,1633`), the feed rows, and the gating predicates
  per handler.
- Topics: each family's success rule and skip behavior, including that a 403 on one
  automod/feed/inbox/trust/points type dooms the rest, widgets break on any failure,
  and `noteSubscribed` fires on success except for widgets.

## Tests

- `test/data/parsing_test.dart` EventSub groups (`:1806-2570`) retarget from
  `EventSubService` to `EventSubDecoder`: `setChannelMapping` and `handleRawMessage`
  become decoder calls (`feed`). Assertions unchanged.
- `test/unit/irc_test.dart` session lifecycle (`:1812-1873`) stays on the transport.
  Subclass seams (`_NoopEventSub` `:156`, `_LiveEventSub` `:161`, `_StaleEventSub`
  `:209`) and `_FakeEventSubService` (`test/widgets/widgets_test.dart:58`) keep
  extending the transport. Import paths only.
- New: `test/unit/eventsub_topics_test.dart` (Stage 2),
  `test/unit/eventsub_consumer_test.dart` (Stage 3).
- No new behavior tests for the pure moves beyond import changes.

## Verification

- Per stage: `dart analyze lib test` clean; `flutter test` green.
- Import rule: `rg "import" lib/eventsub/transport` shows no `models`, `chat`,
  `session`, or `decode` imports.
- Stage 3: every consumer switch is exhaustive; no `case` on a bare string where an
  enum now exists.
- End to end on two or three busy channels: moderation by another mod
  (delete/ban/timeout/warn), shield, shoutout, unban request, AutoMod hold and resolve,
  points reward edit and redemption, broadcaster hype train/poll/prediction, account
  switch, and an EventSub reconnect that resubscribes.

## Out of scope

- `ModActions` and all Helix action/query verbs. They are not EventSub.
- Unifying the IRC moderation echoes (`ChatIngestion`) with the EventSub path into one
  formatter. That is the later "single ingest path" item.
- EventSub behavior changes: reconnect/session semantics and the manager's `??=` rebind
  beyond what the consumer attach fixes. `_channelUserIds` moves to the decoder in A2
  and is intentionally not cleared in this refactor; clearing it on `forgetChannel` or
  `disconnect` is a separate change, so do not clear it mid-move.
- The stringly-typed feed model: `ModActivityEntry.action` (`lib/models/moderation_entries.dart`),
  `mod_activity_format.dart`, and `_activityIcon` in `mod_view.dart` stay string-based.
  The consumer converts the enum back to the wire string.
- 7TV, and renaming `EventSubService`.

## References

- `lib/irc/`: the precedent for a pure protocol leaf, a transport that emits frames, and
  a decode layer that produces domain events.
- `lib/services/mod_actions.dart`: the single Helix action site, untouched.
- `~/dankchat` and `~/chatsen`: the shared principle is a dependency-free protocol leaf
  plus a transport that emits frames and a decode layer that produces domain events.
- `PLAN.md` is the live plan; `I18N.md` holds localization; `BACKLOG.md` holds triage;
  `RULES.md` and `AGENTS.md` apply.
