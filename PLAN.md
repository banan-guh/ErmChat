# IRC reorg (realtime source slice 1)

Status: FROZEN. Make the code match this document; only the user changes it. Do not
open another design round.

This is the concrete plan to reorganize the Twitch IRC layer so `lib/irc/` does only
IRC/transport work, and a separate decode layer lifts data out of frames. It is
written for an implementing agent with zero context. Read the whole document before
touching code. Do not start commit 1 until the plan is approved.

Behavior must not change. This is a structural refactor, not a feature.

## Why

`lib/services/base_irc_connection.dart` (921 lines) and `lib/services/twitch_irc.dart`
(811 lines) fuse three concerns:

- **Transport**: `IrcConnection` (`base_irc_connection.dart:55`) owns the socket loop,
  reconnect/backoff, keepalive, connectivity, join queue/sweep/retry, and the
  connection-level commands (PING/PONG :570, RECONNECT :592, ROOMSTATE join-confirm
  :601, `msg_channel_suspended` :613).
- **Framing**: `parseIrcMessage` (`:823`) and `IrcMessage` (`:891`) are generic IRC but
  live inside the transport file.
- **Decode + copy**: the sockets are the real decoder. `IrcReadService.dispatchLine`
  (`twitch_irc.dart:424`) switches 11 commands and emits typed streams
  (`onMessage`, `onBan`, `onUserNotice`, `onMessageDeleted`, `onChannelClear`,
  `onWhisper`, `onRoomState`, `onUserEmoteSets`, `onNotice`, `onJtvMessage`,
  `onOwnMessage`). The same file holds the codec (`parseIrcChatMessage:684`,
  `parseIrcEmotePositions:146`, `parseIrcGifPositions:205`, `parseIrcBadges:270`) and
  user-facing copy (`userNoticeAccent:104`, `userNoticeLabelId:114`,
  `buildUserNoticeText:121`, `buildBanText:133`).

The socket is therefore the network owner, the Twitch command router, and the domain
decoder at once. Consumers (`ChatIngestion`, `ChatChannelSetup`,
`ChatConnectionManager`) subscribe to socket streams, and two of them re-decode
(`chat_ingestion.dart:442`, `recent_messages.dart:235-548`). `twitch_eventsub.dart` has
the analogous fusion on the JSON side; that is out of scope here.

References agree on the fix. `~/chatsen` has `lib/irc/message.dart` (generic frame,
zero deps) plus `lib/tmi/connection` (transport) and `lib/tmi/client` (decode).
`~/dankchat` has `data/irc/IrcMessage.kt` plus `data/twitch/chat` (transport) and
`data/twitch/message` (decode). Both isolate the wire frame and keep the transport
emitting frames, not domain.

## Ground rules (non-negotiable)

1. `lib/irc/message.dart` imports only `lib/util/irc_utils.dart` and
   `lib/util/log.dart` (`parseIrcMessage` calls `logDebug` on a malformed line). No
   Flutter, no models, no chat.
2. `lib/irc/transport/**` imports no `lib/chat/**`, no `lib/models/twitch_message.dart`,
   no `lib/irc/decode/**`, and no `Session`. It emits `IrcMessage` and connection
   events only.
3. `lib/irc/decode/**` may import `lib/irc/message.dart`, `lib/models/**`,
   `lib/client/session.dart`, and `lib/util/**`.
4. No compatibility facade or barrel. Delete the `twitch_irc.dart` re-exports
   (`twitch_irc.dart:11-19`). Update every call site; compile errors are the checklist.
5. Pure moves are verbatim. Do not "improve" a function while relocating it.
6. Format only touched files (`dart format <file> ...`), never `dart format .`. Keep
   comments short and present-tense. No em-dashes. Do not commit unless told. Follow
   `AGENTS.md` and `RULES.md`.

## Target tree

```
lib/irc/
  message.dart          IrcMessage + parseIrcMessage                  (pure frame)
  transport/
    events.dart         IrcConnectionStatus, IrcSocketRole, JoinFailureReason,
                        IrcJoinFailureEvent
    connection.dart     IrcConnection                                  (transport)
    read.dart           IrcReadService  -> onIrcMessage + onAuthFailed
    write.dart          IrcService      -> onIrcMessage + onAuthFailed
  decode/
    codec.dart          parseIrcChatMessage, parseIrcEmotePositions,
                        parseIrcGifPositions, parseIrcBadges, _cpToUtf16Table
    events.dart         UserNoticeEvent, IrcBanEvent, IrcNoticeEvent,
                        IrcChannelClearEvent, IrcMessageDeletedEvent,
                        IrcRoomStateEvent
    decoder.dart        IrcChatDecoder                                 (the switch)
    copy.dart           buildBanText, buildUserNoticeText, userNoticeAccent,
                        userNoticeLabelId
```

`lib/irc/` means "the Twitch IRC subsystem", not a generic IRC library. The generic
part is exactly `message.dart`, which stays a dependency-free leaf.

## Ownership map (old to new)

| Old symbol | Old site | New home |
| --- | --- | --- |
| `IrcMessage` | `base_irc_connection.dart:891` | `irc/message.dart` |
| `parseIrcMessage` | `base_irc_connection.dart:823` | `irc/message.dart` |
| `_loneLowSurrogateRe`, `_orphanedHighSurrogateRe` | `base_irc_connection.dart:42-43` | `irc/message.dart` (private) |
| `IrcConnectionStatus` | `base_irc_connection.dart:14` | `irc/transport/events.dart` |
| `IrcSocketRole` | `base_irc_connection.dart:40` | `irc/transport/events.dart` |
| `JoinFailureReason` | `base_irc_connection.dart:17` | `irc/transport/events.dart` |
| `IrcJoinFailureEvent` | `base_irc_connection.dart:28` | `irc/transport/events.dart` |
| `IrcConnection`, `_DeathReason`, `_WakeReason`, `_AttemptOutcome` | `base_irc_connection.dart` | `irc/transport/connection.dart` |
| `IrcService` | `twitch_irc.dart:285` | `irc/transport/write.dart` |
| `IrcReadService` | `twitch_irc.dart:371` | `irc/transport/read.dart` |
| `IrcRoomStateEvent` | `base_irc_connection.dart:907` | `irc/decode/events.dart` |
| `IrcBanEvent` | `twitch_irc.dart:23` | `irc/decode/events.dart` |
| `IrcNoticeEvent` | `twitch_irc.dart:39` | `irc/decode/events.dart` |
| `IrcChannelClearEvent` | `twitch_irc.dart:48` | `irc/decode/events.dart` |
| `IrcMessageDeletedEvent` | `twitch_irc.dart:56` | `irc/decode/events.dart` |
| `UserNoticeEvent` | `twitch_irc.dart:72` | `irc/decode/events.dart` |
| `parseIrcChatMessage` | `twitch_irc.dart:684` | `irc/decode/codec.dart` |
| `parseIrcEmotePositions` | `twitch_irc.dart:146` | `irc/decode/codec.dart` |
| `parseIrcGifPositions` | `twitch_irc.dart:205` | `irc/decode/codec.dart` |
| `parseIrcBadges` | `twitch_irc.dart:270` | `irc/decode/codec.dart` |
| `_cpToUtf16Table`, `_replyPrefixRe` | `twitch_irc.dart:256,21` | `irc/decode/codec.dart` (private) |
| `buildUserNoticeText` | `twitch_irc.dart:121` | `irc/decode/copy.dart` |
| `buildBanText` | `twitch_irc.dart:133` | `irc/decode/copy.dart` |
| `userNoticeAccent` | `twitch_irc.dart:104` | `irc/decode/copy.dart` |
| `userNoticeLabelId` | `twitch_irc.dart:114` | `irc/decode/copy.dart` |
| socket typed streams + dispatch | `IrcReadService.dispatchLine` `twitch_irc.dart:424` | `irc/decode/decoder.dart` (`IrcChatDecoder`) |
| `selfBadges` | `twitch_irc.dart:398` | read decoder |

`lib/services/base_irc_connection.dart` and `lib/services/twitch_irc.dart` are
deleted at the end.

## The seam

Transport parses one frame and, for anything it does not consume itself, emits the
`IrcMessage` on a raw stream. Decode subscribes, switches on `command`, and produces
the typed streams. Concretely:

- `IrcReadService` and `IrcService` each expose `Stream<IrcMessage> get onIrcMessage`.
- `IrcChatDecoder` is constructed per socket with that stream and the current nick,
  exposes the typed streams the app consumes, and owns `selfBadges`.
- `ChatConnectionManager` constructs `readDecoder`/`writeDecoder`, re-points its
  subscriptions from `ircRead.onX`/`irc.onX` to the decoder, and `ChatIngestion`
  attaches to the read decoder.

Transport keeps deciding connection-level things because they are transport state:
PING/PONG, RECONNECT, the ROOMSTATE JOIN confirmation, and the suspended-JOIN
refusal. It also keeps fatal-auth detection (`signalFatalAuthFailure`) and
`onAuthFailed`, since a dead token is a connection outcome.

ROOMSTATE is consumed twice by design after the seam: `IrcConnection._handleLine`
uses it to track JOIN confirmation (pending/confirmed sets), and the decoder turns the
same frame into `IrcRoomStateEvent`. Do not merge these. One is transport state, the
other is a typed event.

## Slices

Each slice ends with `dart analyze lib test` clean and `flutter test` green, and is
committed separately only when told. Slices IRC-1 through IRC-4 are pure moves; IRC-5
is the seam and the only behavior-sensitive step.

### IRC-1: frame leaf

- Create `lib/irc/message.dart` with `IrcMessage`, `parseIrcMessage`, and the two
  surrogate regexes moved verbatim from `base_irc_connection.dart`. It imports
  `../util/irc_utils.dart` for `unescapeIrcTag` and `../util/log.dart` for `logDebug`.
- `base_irc_connection.dart` imports `message.dart`; `twitch_irc.dart` imports it and
  drops `IrcMessage`/`parseIrcMessage` from its re-export.
- Update importers: `chat_ingestion.dart` (shows `IrcMessage`), `recent_messages.dart`
  (`parseIrcMessage`), `test/unit/irc_test.dart:3597`, and any others the compiler flags.
- Gate: analyzer clean, tests green.

### IRC-2: transport events

- Create `lib/irc/transport/events.dart` with `IrcConnectionStatus`, `IrcSocketRole`,
  `JoinFailureReason`, `IrcJoinFailureEvent`, moved verbatim.
- `IrcRoomStateEvent` is **not** included here; it moves to decode (it is a decoded
  ROOMSTATE frame, not a transport frame).
- Update importers: `base_irc_connection.dart`, `join_rate_limiter.dart`
  (`IrcSocketRole`), `chat_channel_setup.dart` (`IrcJoinFailureEvent`,
  `JoinFailureReason`), tests.
- Gate.

### IRC-3: decode codec, events, copy

- Create `lib/irc/decode/codec.dart`, `events.dart`, `copy.dart` and move the symbols
  per the ownership map, verbatim. `IrcRoomStateEvent` joins `events.dart`.
- `twitch_irc.dart` (still holding the sockets) imports these; the sockets keep their
  current behavior for this slice.
- Update importers: `chat_ingestion.dart` (`IrcChannelClearEvent`,
  `IrcMessageDeletedEvent`, `buildBanText`, `parseIrcChatMessage`),
  `chat_channel_setup.dart`, `chat_connection_manager.dart` (events + copy),
  `recent_messages.dart` (`parseIrcChatMessage`, `parseIrcBadges`,
  `parseIrcEmotePositions`), and tests.
- Gate.

### IRC-4: relocate transport

- Move `IrcConnection` to `lib/irc/transport/connection.dart`, `IrcService` to
  `write.dart`, `IrcReadService` to `read.dart`. Sockets are still fused (they keep
  the typed streams) so this slice is a pure move. Ground rule 2 is not satisfied
  until IRC-5; `read.dart`/`write.dart` still import `decode/` here by design.
- Delete `lib/services/base_irc_connection.dart` and `lib/services/twitch_irc.dart`,
  including the re-export barrel. Update every importer: `channel_manager.dart`,
  `main.dart`, `home_screen.dart`, `chat_connection_manager.dart`,
  `chat_channel_setup.dart`, `chat_ingestion.dart`, `command_handler.dart`,
  `recent_messages.dart`, and tests.
- Gate.

### IRC-5: the seam

- Create `lib/irc/decode/decoder.dart` with `IrcChatDecoder`. Move the command switch
  and the typed streams out of the sockets.
- `selfBadges` moves from `IrcReadService` to the read decoder. Update every
  reader/writer: `chat_connection_manager.dart:458,497-498,1145`, and the tests that
  set it directly (`test/unit/irc_test.dart:2840,2853,3538`).
- Sockets expose `onIrcMessage` only (plus `sendMessage`, status, join-failed,
  auth-failed inherited/kept). They construct no typed controllers and import no
  models.
- Own-echo is read-side only. Move it into the read decoder, comparing against the
  transport's current nick via a `String? Function()` (pass `() => ircRead.username`).
  `username` is already lowercased at connect (`base_irc_connection.dart:213`), so the
  decoder must preserve `sender == username` verbatim and add no new casing. The write
  decoder takes no nick provider.
- `ChatConnectionManager` builds the decoders and re-points its subscriptions;
  `ChatIngestion.attach()` listens to the read decoder instead of the socket.
- Give `IrcChatDecoder` a `@visibleForTesting void feed(IrcMessage msg)` that calls the
  exact same handler as the `onIrcMessage` stream listener, so the two paths cannot
  diverge.
- Preserve the raw-type details: `onOwnMessage` stays `Stream<IrcMessage>` (raw, not
  `TwitchMessage`), and `selfBadges` stays `Map<String?, Set<String>>` (nullable key
  for GLOBALUSERSTATE) with `clearSelfBadges()`.
- The read-side `PerfLog.I.record('JOINQ', '[$debugPrefix] confirm #$channelName')`
  (`twitch_irc.dart:570`) moves into the decoder's ROOMSTATE handler.
- Port the tests: transport groups stay on the sockets and assert `onIrcMessage`;
  decode tests feed `IrcChatDecoder.feed`. Replace all five helpers: `emitChatMessage`,
  `emitOwnMessage`, `emitWhisper`, `emitUserNotice`, `emitRoomState` (used in
  `test/unit/irc_test.dart` and `test/widgets/widgets_test.dart`).
- Update `AGENTS.md:41`, whose test-conventions line still names
  `IrcService.emitChatMessage`/`emitUserNotice`.
- Gate: full `flutter test` green with every old test still meaningful.

## Behavior to preserve (move verbatim, do not "improve")

- Frame parse: tags first, then prefix, then command, then params with a leading
  `:` starting the trailing. Tag values are `unescapeIrcTag`-decoded, then lone low
  surrogates and orphaned high surrogates are stripped (`base_irc_connection.dart:42-43`).
- `_handleLine` order: split on `\r\n`, reset the reconnect attempt per line, handle
  PING/PONG/RECONNECT before `dispatchLine`, and return early from the batch when a
  fatal auth failure is flagged (`base_irc_connection.dart:627-632`).
- ROOMSTATE confirm: strip `#`, remove from pending, add to confirmed, only for a
  channel this socket joined (`:599-607`).
- Suspended JOIN: `msg-id == msg_channel_suspended`, param starts with `#`, emit
  `IrcJoinFailureEvent` once per channel per socket (`:609-625`).
- `IrcService.dispatchLine`: ROOMSTATE, then NOTICE (auth-failed, else send rejection
  as `IrcNoticeEvent` with `channel`, `message`, `msgId`) (`twitch_irc.dart:316-346`).
- ROOMSTATE on both sockets: strip `#`, emit `IrcRoomStateEvent(channel, tags)`
  (`twitch_irc.dart:565-575`, `:348-357`).
- `IrcReadService.dispatchLine` command set and JTV routing: PRIVMSG whose prefix
  contains `jtv.tmi.twitch.tv` goes to `onJtvMessage`, else `onChatMessage`
  (`twitch_irc.dart:448-454`).
- `CLEARCHAT`: no target means channel clear; with target, emit `IrcBanEvent` with
  `ban-duration`/`target-user-id` (`:458-484`).
- `CLEARMSG`: require `target-msg-id`, user from `login` or `unknown`, text from
  trailing (`:486-505`).
- NOTICE: param `*` or absent means auth-failed check only; otherwise emit
  `IrcNoticeEvent` (`:507-530`).
- USERSTATE/GLOBALUSERSTATE: return when both `emote-sets` and `badges` are absent;
  emit emote-sets when present; set `selfBadges[channel]` from the badge set ids
  (`:544-563`).
- WHISPER: require a trailing; emit `parseIrcChatMessage(msg, channel: null)`
  (`:642-645`).
- USERNOTICE: `sharedchatnotice` with `source-msg-id == announcement` becomes
  `announcement`; login from tags or prefix, lowercased; badges and emote positions
  parsed (`:577-620`).
- Own echo: emit on both `onChatMessage` and `onOwnMessage` when the prefix login
  equals the socket nick, lowercased (`:634-639`).
- `parseIrcChatMessage`: display-name/login resolution, id fallback
  `id`/`message-id`, ACTION unwrap, reply `@user ` prefix trim with `prefixLen`
  shift, timestamp from `tmi-sent-ts`, color fallback, `source-room-id` mirroring,
  `source-id`, bits, and all tag pass-throughs (`twitch_irc.dart:684-811`).
- Copy text exactly: `buildBanText` ("was timed out for X." / "was banned."),
  `buildUserNoticeText` ("Announcement" for announcements, else `system-msg` or
  "`displayName` `msgId`."), `userNoticeAccent`, `userNoticeLabelId`.
- `ChatConnectionManager` suppression logic stays: moderation-active NOTICE
  suppression, join-failure NOTICE dedup, write-socket send-rejection system messages,
  sub/resub child chat message with shifted emote positions.

## Tests

- `test/data/parsing_test.dart` (2877 lines) pins the codec functions. It changes only
  by import once IRC-3 lands.
- `test/unit/irc_test.dart` (4141 lines) is the main port in IRC-5. Keep every
  assertion; change only how events are delivered. Transport tests drive `handleLine`
  and assert `onIrcMessage`; decode tests feed the decoder.
- `test/widgets/widgets_test.dart:4489` uses `parseIrcBadges`; update the import.
- `test/unit/chat_ingestion_test.dart`, `test/unit/auth_services_test.dart`,
  `test/chat/channel_manager_test.dart` update imports and any `IrcService` /
  `IrcReadService` construction to the new homes.
- No new behavior tests are required for the pure moves. For IRC-5, add fixture tests
  for the decoder command set only where the old socket tests do not already cover it.

## Verification

- Per slice: `dart analyze lib test` clean; `flutter test` green.
- End to end on two or three busy channels: chat renders, emotes/badges render,
  reply prefixes, bans/timeouts/deletions, whispers, room-state changes, slow mode,
  own-message echo and self-timeout heal, account switch, anonymous read-only.
- Specifically verify the three drift-prone semantics: write-socket NOTICE send
  rejection, own-echo comparison, and the `sharedchatnotice` announcement unwrap.
- Confirm the import rule holds: `rg "import" lib/irc/transport` shows no `models`,
  `chat`, `session`, or `decode` imports.

## Out of scope

- `ChatConnectionManager`, `ChatChannelSetup`, `ChatIngestion` internals. Only their
  subscription source changes in IRC-5.
- EventSub and 7TV. They get the same `transport/` + `decode/` treatment as separate
  slices later.
- Unifying `IrcService`/`IrcReadService` into one role-parameterized class, and
  renaming the socket classes.
- The broader pipeline concern split (SystemLines, JoinQueue, Outbox, EventSubTopics).
- Any behavior change to parsing, filtering, or transport.

## References

- `~/dankchat` (Kotlin) and `~/chatsen` (Flutter): the shared principle is a
  dependency-free protocol leaf plus a transport that emits frames and a decode layer
  that produces domain events.
- `~/ermchat`: the clean `main` reference for behavior.
- `PLAN.md` is the live plan; `I18N.md` holds localization; `BACKLOG.md` holds
  triage; `RULES.md` and `AGENTS.md` apply.
