# Hot-Reload Audit Plan

Audit of places where a state change should immediately update the chat but doesn't
(requires a restart or a manual force-refresh). Discovered Aug 2026, not yet implemented.

## A. Login / account flow (sub emotes don't load until restart)

### A1. Sub emotes stale after logout -> login or account switch (PRIMARY)

- `_fetchedEmoteSetIds` / `_inflightEmoteSetIds` / `_emoteOwnerLogins` /
  `_emoteOwnerLookupDone` (`lib/screens/home_screen.dart:236,240,243,244`) are
  session-lifetime and never cleared on auth change.
- Logout/switch: `_refreshEmotesAfterAuth` -> `EmoteManager.evictChannel` wipes
  `_channelTwitchEmotes` (`lib/services/emote_manager.dart:860`).
- Re-login: GLOBALUSERSTATE/USERSTATE arrives but `_loadUserEmoteSets`
  (`home_screen.dart:1126-1134`) dedups every set ID against `_fetchedEmoteSetIds` ->
  `newSetIds.isEmpty` -> early return. Sub emotes stay gone until restart (fresh
  process = empty dedup).
- `_emoteOwnerLookupDone` (`home_screen.dart:1200`) also blocks owner resolution for
  a second account, mislabeling its sub emotes.

Fix: in `_onAuthChanged` (`home_screen.dart:954`), inside the existing account-changed
branch, clear `_fetchedEmoteSetIds`, `_inflightEmoteSetIds`, `_emoteOwnerLogins`, and
reset `_emoteOwnerLookupDone`.

### A2. Login during an in-flight connect is silently lost

- `ChatConnectionManager.connect()` drops any call while `_isConnecting`
  (`lib/services/chat_connection_manager.dart:1080`). `hasToken` is snapshotted early
  (line 1164); if login lands while the startup connect is still awaiting network,
  `_onAuthChanged`'s `connect()` is dropped, and the stale `hasToken=false` forces the
  anonymous branch (line 1200). IRC stays justinfan, no USERSTATE arrives -> no sub
  emotes, "Connect an account to chat" persists.

Fix: in `connect()`'s `finally` (`chat_connection_manager.dart:1237`), re-run connect
if the sockets' last-used credentials (`_lastIrcUsername` / `_lastIrcToken`) no longer
match the live auth. Recovers a login that landed mid-connect without redundant
reconnects on the normal path.

### A4. Per-account caches not reset on switch

- `_blocksFetched` (`home_screen.dart:223/501`) keeps the old account's block list;
  the new account's list is never fetched.
- `_mentionScanDone` (`home_screen.dart:315`) skips the new account's retroactive
  mention scan.
- `_channelsEmotesResolved` (`home_screen.dart:233`) is only cleared on channel removal
  (`home_screen.dart:1759`), so `subscribeChannel` skips re-resolving with the new
  token (`chat_connection_manager.dart:711`) after a switch.

Fix: reset `_blocksFetched`, `_mentionScanDone`, and `_channelsEmotesResolved` in
`_onAuthChanged` when the account changes (same branch as A1).

## B. Settings propagation

### B1. Six chat settings only apply after Settings closes

"Apply only after settings close" = the chat reads these values only when the whole
Settings route stack is popped (`_loadMaxMessages`, `home_screen.dart:1222`, re-read at
`home_screen.dart:1923-1929`). While any settings sub-screen is open, changes are
invisible to the chat.

Affected (`lib/screens/settings/chat_settings_screen.dart`), each persisted to prefs +
local state with no callback to HomeScreen:
- timestamp format (:100-102)
- max messages per channel (:129-135)
- recent messages to load (:154-160)
- reply to thread root (:181-185)
- prefer emote suggestions (:192-197)
- show timestamps (:203-207)

Only background-service and mention-push have live callbacks
(`lib/screens/settings/settings_screen.dart:102-103`).

Fix: thread `ValueChanged` callbacks for these six settings through `SettingsScreen` ->
`HomeScreen` setters (pattern already used by background/mention-push), applying the
value to HomeScreen state immediately.

### B2. Lowering "Max messages per channel" never truncates on-screen buffers

The cap is only enforced on the message hot path (`_truncateWithCoalesce`,
`chat_connection_manager.dart:669`), so reducing it does nothing until the next
incoming message.

Fix: when the cap changes, run `truncateChannelMessages` across channels.

### B3. Channel reorder has no setState

`_reorderChannels` (`home_screen.dart:485-495`) clears/re-adds `_channels` and bumps
`_channelNotifier` but calls no `setState`; the tab bar builds from the plain
`_channels` list (`home_screen.dart:2750`) and doesn't listen to `_channelNotifier`.
The new order only reaches the bar via the incidental settings-pop rebuild.

Fix: `setState` in `_reorderChannels` (or have the tab bar listen to
`_channelNotifier`).

### B5. True-dark change doesn't clear the tile cache

`onTrueDarkChanged` is passed through unwrapped (`home_screen.dart:1904`) while
theme/accent wrap with `_tileCache.clear()` (`home_screen.dart:1900,1906`). True dark
changes `colorScheme.surface`, which is baked into cached message tiles. Currently
masked by the pop-time `_tileCache.clear()` at `home_screen.dart:1927`; any
non-settings path (e.g. OS dark-mode switch with `themeMode == system`) shows stale
colors.

Fix: wrap `onTrueDarkChanged` with `_tileCache.clear()`.

## Discarded (audited, intentionally not fixing)

- **A3. Badge spans never invalidated** (`lib/widgets/message_builder.dart:74`,
  `lib/models/twitch_message.dart:55`): `cachedBadgeSpans` has no version guard, and
  badge fetches never notify, so messages rendered before badges resolve stay
  badge-less. Discarded by request.
- **B4. Alt pings don't re-render existing messages** (`home_screen.dart:1236`;
  highlight only computed at message arrival, `chat_connection_manager.dart:1564`).
  Updating earlier messages on a ping change is unwanted. Discarded by request.
- **B6. Dev "Test chat widgets" toggle only applies on full settings exit**
  (`dev_settings_screen.dart:34`, applied via `_loadTestWidgets` at
  `home_screen.dart:1338/1926`). Not fixing.

## Out of scope

- Emote `accessToken` setter is silent (`emote_manager.dart:352`); `subscribeChannel`
  sets it without a refetch for already-resolved channels
  (`chat_connection_manager.dart:706-711`). Covered by A4's
  `_channelsEmotesResolved` reset; no separate change.

## Verification

`dart format .`, `flutter analyze`, `flutter test`, then a live check: login/logout/
switch accounts and confirm sub emotes appear without restarting; change the six chat
settings and confirm they apply immediately.

---

# Full Code Audit (Aug 2026)

Not yet implemented. Baseline at audit time: `flutter analyze` clean, 741/741 tests pass.
Phases 1-3 in scope; the home_screen.dart split and OAuth scope cosmetics are explicitly
out of scope for now.

## A. Critical (user-visible bugs)

### A5. IRC dispatch by `contains()` drops or misroutes messages

- Problem: `IrcService.dispatchLine` (`lib/services/twitch_irc.dart:300-346`) routes on
  `line.contains(...)`, which matches the *trailing chat text*, not the command. A
  PRIVMSG whose text contains `"NOTICE "`, `"WHISPER "`, `"CLEARCHAT "`, `"CLEARMSG "`,
  `"USERNOTICE "`, `"USERSTATE "`, `"ROOMSTATE "`, or `":jtv "` goes to the wrong
  handler, gets rejected on its command check, and is silently dropped. `:jtv ` is
  worse: `_handleJtvMessage` (:423) never checks the command, so such a message is
  re-rendered as a fake system notice. Every line is also parsed twice
  (`base_irc_connection.dart:328` splits for `cmd`, then the handler re-parses).
- Solution: parse each line once (in `_handleLine` or at the top of `dispatchLine`),
  then `switch (msg.command)`; keep the jtv branch as a `PRIVMSG`-check only when
  `msg.prefix` contains `jtv.tmi.twitch.tv`. Delete `_handleJtvMessage`'s special-case
  routing once dispatch is command-based. Verify against the IRC data tests.

### A6. EventSub reconnects never re-subscribe until an IRC reconnect

- Problem: EventSub subscriptions are session-scoped, but the status listener
  (`chat_connection_manager.dart:1092-1099`) only reacts to `disconnected` (clearing
  `_moderationChannels`/`_widgetChannels`). On `connected` (new session from
  `session_reconnect`, `twitch_eventsub.dart:352-364`, or keepalive reconnect
  :368-376), nothing re-runs `_subscribeModeration`/`_subscribeWidgets`, so
  `channel.moderate` and hype-train/poll/prediction widgets stay dead until the IRC
  socket happens to reconnect. The comment at :1089-1091 even claims re-creation.
- Solution: in the `statusSub` listener, on `EventSubStatus.connected` re-run a
  subscribe pass for the current channels (respecting the skipped sets and the
  `_lastSubscribeAll` throttle).

### A7. Account switch keeps old block list and skips mention scan

- Problem: `_ensureBlockedUsersLoaded` early-returns once `_blocksFetched` is true
  (`home_screen.dart:500-522`), and `_mentionScanDone` (:315) is never reset, so after
  an account switch the new account inherits the old account's block list and never
  gets its retroactive mention scan.
- Solution: covered by A4 above (reset `_blocksFetched`, `_mentionScanDone` in
  `_onAuthChanged`); also clear `_blockedLogins` and sweep the mentions channel.

### A8. Auth load failure hangs the app on the loading spinner

- Problem: `await _twitchAuth.load()` (`lib/main.dart:99`) sits outside the try/catch
  that wraps prefs; a `FlutterSecureStorage` failure (platform-channel/keychain issue)
  throws, `_loaded` never becomes true, and the app spins forever with no error.
- Solution: wrap the call in try/catch and fall back to anonymous state.

## B. Correctness (small, high value)

### B7. Moderation/widget skip sets persist across account switches

- Problem: `_moderationSkippedChannels`/`_widgetSkippedChannels`
  (`chat_connection_manager.dart:219-230`) are filled from 403s and never cleared on
  account change, so a non-mod account's skip permanently disables moderation and
  broadcaster widgets for a mod account on the same channel.
- Solution: clear both sets when the account-identity check in `connect()`
  (:1194-1198) detects a switch.

### B8. `fetchChatStatus` throws unhandled async exceptions every 60s

- Problem: the timer-driven `fetchChatStatus` (:521-545, ticked at :745-748) has no
  try/catch; any `SocketException`/`TimeoutException`/`ClientException` (the last will
  happen after `_httpClient.close()` in dispose) surfaces as an uncaught zone error per
  channel per tick.
- Solution: wrap the body in try/catch and return early on failure.

### B9. Connect-vs-dispose race in `base_irc_connection`

- Problem: `_connect()` (`base_irc_connection.dart:73-147`) has no `_disposed` check
  after `await _waitForReady`; if dispose runs mid-handshake (account switch, teardown),
  `_connect()` resumes, sends CAP/PASS/NICK/JOIN, and calls
  `_statusController.add(...connected)` on a closed controller, throwing `StateError`
  and leaking the socket.
- Solution: after the await, `if (_disposed) { newChannel.sink.close(); return; }`, and
  guard each `_statusController.add` with `_disposed`.

### B10. `_removeChannel` leaves stale per-channel state

- Problem: `_removeChannel` (`home_screen.dart:1752-1794`) disposes the scroll
  controller but never cleans `_chatVersions`, `_messageNotifiers`,
  `_atBottomNotifiers`, `_tileCache`, or `_frozenSnapshot` for the removed channel;
  re-joining reuses stale notifiers and an old frozen snapshot, and the maps grow for
  the session.
- Solution: `remove` + `dispose` the per-channel notifier/tile-cache entries in
  `_removeChannel`.

### B11. Persisted enum index can crash startup

- Problem: `EmoteFetchAutoMode.values[autoIndex]` indexes the enum from a raw persisted
  int with no bounds check (`home_screen.dart:982`,
  `emotes_settings_screen.dart:60`); a corrupt/old prefs value throws `RangeError` at
  startup.
- Solution: clamp or fall back to `defaultEmoteFetchAutoMode` on out-of-range.

### B12. iOS mention-notification toggle silently does nothing

- Problem: on iOS, `_initNotificationInfra`/`_setMentionPush` early-return
  (`notification_service.dart:75-79`), permission is never requested, and the
  `DarwinNotificationDetails` set `presentAlert/presentBadge/presentSound: false`, while
  the toggle shows on iOS (`chat_settings_screen.dart:236`).
- Solution: hide the toggle on iOS until push is implemented.

### B13. Notification IDs collide within the same second

- Problem: IDs are `DateTime.now().millisecondsSinceEpoch ~/ 1000`
  (`notification_service.dart:89`); two mentions in the same second replace each other.
- Solution: use a monotonically increasing counter (or random suffix).

### B14. IRC tag unescaping uses the wrong scheme and wrong order

- Problem: `parseIrcMessage` decodes tags with `Uri.decodeComponent` (percent-encoding)
  while Twitch IRCv3 uses backslash escapes (`\s`, `\:`, `\\`, `\r`, `\n`); literal
  percent-sequences in a tag value get mangled. The app's own `unescapeIrcTag`
  (`lib/util/irc_utils.dart:1-8`) is only applied to a few tags and its sequential
  `replaceAll` order mis-decodes `\\s` (`\s` is replaced before `\\`).
- Solution: write one single-pass scanner handling `\\` first, then the other escapes,
  and use it for all tags in `parseIrcMessage`.

### B15. `TapGestureRecognizer` leak per URL per message

- Problem: `parseTextWithLinks` (`lib/widgets/emote_text.dart:357-359`) creates a fresh
  recognizer per URL in every span list and never disposes them; recognizers are
  caller-owned, so URL-bearing messages leak one each (spans are cached per message).
- Solution: share one recognizer instance per built message, or dispose with the tile.

### B16. Engine codec never disposed on the GIF decode path

- Problem: `_decodeWithEngineCodec` (`lib/widgets/emote_image.dart:149-159`) never calls
  `codec.dispose()` (unlike `_decodeStatic` at :440-451), leaking native memory per
  seeded-GIF decode. Also `ui.decodeImageFromPixels` (:465-475) invokes its callback
  with `null` on failure, causing an unhandled async type error.
- Solution: wrap the frame loop in try/finally with `codec.dispose()`; guard
  `if (image != null)` in the callback.

### B17. `markEmoteViewed` fires during `build()`

- Problem: `autocomplete_dropdown.dart:81` and `emote_menu_panel.dart:445` call
  `markEmoteViewed` from `itemBuilder`/grid item builders, i.e. on every rebuild of
  every visible row (per keystroke in the autocomplete), over-reporting usage and
  churning the flush timer.
- Solution: record in a post-frame callback or on actual visibility/`onTap`.

### B18. `messageKeys` grows unboundedly for the session

- Problem: every live/history message ID is added to `messageKeys`
  (`chat_connection_manager.dart:1589-1591`) and only removed on channel leave; a long
  session leaves tens of MB of `"$channel:$id"` strings that are never reclaimed even
  though the messages are truncated. (Not thread-related; thread retention is intended.)
- Solution: prune keys for IDs that fall out of the buffer inside
  `truncateChannelMessages`.

### B19. "+N more options" off-by-one in PollCard

- Problem: `chat_widget_cutout.dart:307` shows `choices.take(2)` but appends "+N more"
  only when `choices.length > 3`; exactly 3 choices shows 2 with no note.
- Solution: `> 2` (or render 3).

### B20. Dead code cleanup

- Problem: `user_profile_sheet.dart:245-247` dead ternary (both branches identical);
  commented-out padding in `chat_view.dart:115`; unused variable path in
  `mentions_panel.dart:52-53`; unreachable `default:` in `emote_menu_panel.dart:234-235`;
  unused `hour` parameter on `EmoteUsageRecord.score()`
  (`emote_manager.dart:116-126`); `EmoteImage.placeholder` never passed by callers; the
  30s `_lastSubscribeAll` throttle never triggers (reset on every disconnect,
  `chat_connection_manager.dart:1101-1150`); redundant post-frame `setState` after
  `_addChannel`/`_removeChannel` (`home_screen.dart:1741,1791`).
- Solution: delete each; the jtv special-case dies with A5.

### B21. Full-screen rebuild storm during Mentions/Whispers tab swipes

- Problem: `_onMentionsTabChanged` (`home_screen.dart:2461-2469`) calls `setState` on
  every `_mentionsTabCtrl` notification, and `TabController` notifies on every animation
  tick while `indexIsChanging` (swipe between tabs), rebuilding the entire 3200-line
  `HomeScreen.build` per frame.
- Solution: `if (_mentionsTabCtrl.indexIsChanging) return;` before the setState (pattern
  already used by `emote_sheet.dart:33-35` and `tabbed_layout.dart:121`).

### B22. Drive-bys

- Problem: `text.split(RegExp(r'\s+'))` recompiles the pattern per invocation
  (`command_handler.dart:158,221`); `altPings.any((p) => loweredText.contains(
  p.toLowerCase()))` re-lowercases every alt ping per message
  (`chat_connection_manager.dart:1566-1568`).
- Solution: hoist `RegExp(r'\s+')` to a `static final`; precompute lowered alt pings on
  set.

## C. Performance

### C1. Cached emotes re-downloaded from the CDN when the disk cache is full

- Problem: `fetchEmoteBytes` (`lib/widgets/emote_image_provider.dart:30-48`)
  short-circuits to a direct HTTP fetch when `isFull()`, never consulting the repo; in
  steady state (default cap 500 files) even emotes already on disk are re-downloaded on
  every in-memory miss. Inconsistent with `getSingleFile`
  (`emote_cache_manager.dart:166-170`), which correctly serves the cached copy when
  full.
- Solution: in `fetchEmoteBytes` (and `_serveFromMemory`), try
  `config.repo.get(url)`/`getFileFromCache` before falling back to the network.

### C2. `emoteById` linear scan in the chat hot path

- Problem: `emoteById` (`emote_manager.dart:497-518`) linearly scans every cached emote
  (global + all open channels) and is called once per emote occurrence per message
  (`chat_connection_manager.dart:1549`); a busy channel does thousands of string
  compares per message on the main isolate.
- Solution: maintain a `Map<String, GenericEmote>` id index, rebuilt on cache updates.

### C3. Provider JSON parsed on the main isolate

- Problem: 7TV/BTTV/FFZ/Twitch emote JSON (~1.5-2MB / ~6k emotes for 7TV global) is
  decoded, parsed, and map-built on the UI thread at startup and on each 12h rake
  (`seven_tv_emotes.dart:25,38`, `twitch_emotes.dart:24,50,86`, `bttv_emotes.dart:15,29`,
  `ffz_emotes.dart:14,36`, `emote_manager.dart:1308`); the persisted-cache load
  (`_loadFromPrefs`) has the same issue.
- Solution: run decode + parse + map build inside `Isolate.run`.

### C4. `_precacheQueue` unbounded

- Problem: `enqueueSeenEmotes` is fed per chat message
  (`chat_connection_manager.dart:511`) and the `_seenEmoteIds` dedup set clears itself
  above 2000 entries (`emote_manager.dart:1541-1562`), re-enabling re-enqueue of
  everything; a fast channel outpaces the 5-wide drain.
- Solution: cap the queue (drop when over N) and grow the dedup set with a cap + LRU
  instead of clearing it.

### C5. O(n) `insert(0)` per message in the hottest path

- Problem: `channelMessages[channel]!.insert(0, msg)`
  (`chat_connection_manager.dart:1586`) shifts the whole buffer (up to 2x cap) on every
  chat message, synchronously on the WebSocket event loop, plus per-message string
  interpolations for the `messageKeys` key.
- Solution: store messages newest-last (append + reverse on render) or use a deque.

### C6. Badge service hardening

- Problem: `_globalFetched` is set even when the fetch failed (`twitch_badge_service.dart:15-24`),
  so global badges are never retried until restart; channel badge/avatar fetches have no
  in-flight dedup; HTTP calls have no `.timeout()` or transient-error handling.
- Solution: set `_globalFetched` only on success, memoize in-flight futures, and add
  `.timeout(httpTimeout)` + retryable 429/5xx handling.

## Out of scope (audited, intentionally not fixing)

- **Refresh-token plumbing in `TwitchAuth`** appears dead (implicit grant never issues
  a refresh token, no `/oauth2/token` call exists) but is kept as scaffolding for a
  future auth-code flow.
- **`_onInputChanged` per-keystroke filtering cost** (`home_screen.dart:716-774`) -
  intended.
- **Foreground-service placeholder strings** (`foreground_task.dart:67-68`) - intended.
- **Thread-related memory retention** - intended (threads should be forever).
- **home_screen.dart split** (3226 lines, ~640-line `build()`): worth doing as a staged
  refactor (chat state controller, emote-policy controller, overlay-panel machinery),
  but deferred.
- **OAuth scope list** hardcoded as one URL string with literal `%20`
  (`twitch_oauth.dart:88-96`): works (Twitch form-decodes `+`/`%20`); readability fix
  only (const scope list + `Uri`-built query).
- Marginal, not worth the churn: timestamp width guess `ts.length * 8.5`
  (`chat_message_tile.dart:187`), `EmoteImage.placeholder` dead param, dialog
  `TextEditingController` leaks (`join_channel_dialog.dart:7`, `pings_screen.dart:28`),
  per-emote `Isolate.run` spawn cost, `_evictLowest` O(n) shape outside bursts,
  `_tagToUtf16` O(n*m) scan, clock-backwards histogram bucket bump, three duplicate
  pagination loops in `twitch_api.dart`, `rm-received-ts` epoch-0 fallback inconsistency
  (`recent_messages.dart`), `debugPrint` on every Twitch parse (`twitch_emotes.dart:182`).
