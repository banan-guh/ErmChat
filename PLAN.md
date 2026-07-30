# Performance Audit

## Critical (jank-causing)

- [ ] **#1 `truncateChannelMessages` O(n^2) `removeAt` loop** -- `chat_connection_manager.dart:411-415`. Removes extras by calling `removeAt(i)` in a loop, each call shifts subsequent elements. Fix: build a new retained list in one O(n) pass. Plus fast path: `removeRange` for small overflow and only run thread-aware algorithm when excess > 3.

- [ ] **#2 `_onInputChanged` missing debounce** -- `home_screen.dart:348-369`. Every keystroke iterates 5000 users + 500 emotes with string operations, calls `_checkAutocompleteUndo` (heavy logic for a rare edge case), and triggers autocomplete rebuild. `_autocompleteTimer` field declared at line 169 but never wired. Fix: debounce 150ms, skip `_checkAutocompleteUndo` until after cheap length check, only query users on `@` prefix.

- [ ] **#3 `EmoteManager` global `ChangeNotifier` cascading rebuilds** -- `emote_manager.dart` + `emote_menu_panel.dart`. `notifyListeners()` fires for any emote change in any channel during startup, causing ~2+3N async calls (N = channels). Each triggers `_loadRecentEmotes` + `setState`. Fix: dedicated `ValueNotifier` for recent emotes; batch notifications; per-channel notifiers.

- [ ] **#4 `filterSuggestions` double-iterates all emotes** -- `suggestion.dart:83-94`. Two separate `for` loops over the same list doing `contains` checks, doubling emote iteration. Fix: single pass with `||`.

- [ ] **#5 `parseTextWithLinks` runs on every text segment** -- `emote_text.dart:324-357`. Called for every text segment in every message even when zero URLs present. Falls through full regex match for nothing. Fix: quick `if (!text.contains('.')) return` guard skips 99% of messages.

## Medium

- [ ] **#6 `_onEmotesChanged` clears ALL messages' `cachedSpans`** -- `home_screen.dart:501-518`. Any emote refresh iterates every channel x every message clearing span caches. Fix: per-channel invalidation; use an `emoteVersion` token to skip re-computation.

- [ ] **#7 `_computeThreadMessages` runs on every message even when panels closed** -- `home_screen.dart:520-531`. Builds `parentOf` map + walks all messages + sorts -- O(n log n) per message -- with thread/mentions panels hidden. Fix: guard with `if (_activePanel == OverlayPanel.thread)` checks.

- [ ] **#8 `Theme.of(context)` + `RegExp` recreated per call** -- `chat_message_tile.dart`, `emote_text.dart:326`, `command_handler.dart:21`. `Theme.of(context)` called 3x in `ChatMessageTile.build()`, `RegExp(r'\s+')` compiled per call in hot paths. Fix: hoist to local variables / `static final` constants.

- [ ] **#9 `CachedNetworkImage` per badge per message** -- `home_screen.dart:2018-2100`. Every message rebuild creates fresh `CachedNetworkImage` widgets for each badge (400-600 per full rebuild). Fix: extract reusable `BadgeWidget`, wrap in `RepaintBoundary`.

- [ ] **#10 Both overlay panels always in tree** -- `home_screen.dart:1634-1790`. Thread sheet and mentions sheet widget trees always built and laid out behind `IgnorePointer`. Fix: use `Offstage` or conditional mounting.

- [ ] **#11 `markEmoteUsed` does SharedPreferences I/O on user tap** -- `emote_manager.dart:167-176`. Every emote click triggers SharedPrefs read + write + JSON encode + `_notify()` (~5-50ms I/O on user interaction). Fix: debounce writes, keep in-memory cache, skip `_notify()`.

- [ ] **#12 Manual `ValueListenable` + `setState` in panels** -- `thread_panel.dart:60-77`, `mentions_panel.dart:60-64`. Every data change triggers full widget tree rebuild. Fix: replace with `ValueListenableBuilder` scoped to the content area.

- [ ] **#13 `TapGestureRecognizer` created per build** -- `chat_message_tile.dart:77-86`, `emote_text.dart:341-342`. New recognizer allocated every time a tile/span builds -- 20+ allocations per frame in a 20-visible-item `ListView`. Fix: cache via `StatefulWidget` + `didUpdateWidget`, or use `InkWell`.

## Minor

- [ ] **#14 `_frozenSnapshot` doubles message memory** -- `home_screen.dart:149,2122-2124`. Shallow-copies the entire message list when user scrolls up. Fix: track offset + pre-roll count instead of duplicating the list.

- [ ] **#15 `_userStore` uses `LinkedHashMap<String, void>` with null values** -- `user_store.dart:5,9-15`. Wastes value slot on every entry. Fix: use `LinkedHashSet<String>` from `dart:collection`.

- [ ] **#16 `LayoutBuilder` per emote grid cell** -- `emote_menu_panel.dart:290-305`. Each of ~50 grid items has a `LayoutBuilder` for a simple padding computation. Fix: precompute cell width from grid dimensions and use `Padding` directly.

- [ ] **#17 `command_handler.dart` user ID lookups make HTTP call per command** -- lines 73, 99, 139, 222. `/ban`, `/timeout`, etc. resolve username-to-ID via network every time. Fix: local `Map<String, String>` cache for the session.

- [ ] **#18 `isMention` duplicated in two files with regex split** -- `home_screen.dart:2240-2247`, `chat_connection_manager.dart:1083-1090`. Same function defined twice, each uses regex split allocating intermediate strings. Fix: single canonical copy, manual char iteration.

## Existing bugs (preserved)

- [x] **1 HIGH** `twitch_badge_service.dart:62` -- `clearChannel()` defined but never called. Badge data accumulates per channel forever.
- [ ] **2 HIGH** `home_screen.dart:348-369` -- `_onInputChanged()` has no debounce -- `filterSuggestions` iterates 5000 users + 500 emotes per keystroke. `_autocompleteTimer` field at line 169 is declared but never wired up.
- [x] **3 MEDIUM** `emote_manager.dart` -- No `dispose()` override. `ChangeNotifier` listener list never formally cleared.
- [ ] **4 LOW** `home_screen.dart` -- `_suggestionsNotifier` (line 168) and `_channelNotifier` (line 146) not disposed.
- [ ] **5 LOW** `twitch_badge_service.dart` -- `_channelAvatars`, `_channelNames` never cleaned up (only accumulated, no removal).

## Rebuild Scope Optimization

Focus: making each rebuild cheaper/faster rather than preventing rebuilds from being called.

- [ ] **R1 Per-channel chat version notifier (high impact)** — `home_screen.dart:149,1591-1666`. A single `_chatVersion` listener wraps the entire `TabbedLayout`. Every message arrival calls `pageBuilder` for ALL channels (`tabbed_layout.dart:237-240`). Fix: give each channel its own `ValueNotifier<int>`; `_buildChat` returns a `ListenableBuilder` listening only to its own channel's notifier. Remove `_chatVersion` from the outer wrapper. Pass `onChannelMessage(String channel)` callback to `ChatConnectionManager`.

- [ ] **R2 Per-message keys + RepaintBoundary in ListView** — `home_screen.dart:2182-2218`. `ListView.builder.itemBuilder` has no `key` on items, so every rebuild creates new `ChatMessageTile` widgets for all visible messages. Fix: add `key: ValueKey(msg.messageId)` to each `ChatMessageTile` and wrap in `RepaintBoundary` so Flutter can match old/new widgets and skip repainting unchanged tiles.

- [ ] **R3 Decouple scroll state from _chatVersion** — `home_screen.dart:2156-2168`. Scroll-up/down bumps `_chatVersion` just to toggle the FAB, cascading into full panel data recalculation. Fix: make `_isAtBottom` a `ValueNotifier<bool>` per channel; FAB visibility driven directly by the notifier. No version bump needed.

- [ ] **R4 Lazy panel data computation** — `home_screen.dart:536-547`. `_onPanelDataChanged` runs on every `_chatVersion` bump iterating all messages, even when thread/mentions panels are closed. Fix: early return `if (_activePanel == OverlayPanel.closed) return;` at the top. Or move the listener registration to panel-open time.

- [ ] **R5 Hoist Theme.of/MediaQuery outside ListView builder** — `home_screen.dart:2143-2144`. `Theme.of(context).colorScheme.surface`, `MediaQuery.textScalerOf(context).scale(1.0)`, and `s` are computed once per `_buildChat` call but captured in the `itemBuilder` closure anyway. Fix: already hoisted to local vars — verify no redundant calls in `itemBuilder`.

- [ ] **R6 Cache expensive closures passed to ChatMessageTile** — `home_screen.dart:2192-2193`. `_buildBadgeSpans` and `_buildMessageSpans` are re-created as closures every `_buildChat` call. While Dart caches tear-offs for static methods, these instance methods with `badgeScale` default parameters may allocate new closures. Fix: verify closure identity; if not tear-offs, extract to method tear-offs (`_buildBadgeSpans` without closure wrapper).

- [ ] **R7 Reduce badge widget allocation per message** — `home_screen.dart:2066-2076`. `_buildBadgeSpans` creates a fresh `CachedNetworkImage` per badge per rebuild. With 400-600 badges visible in a full rebuild, this is significant. Fix: extract a `BadgeWidget` with `const`-style caching; wrap in `RepaintBoundary`.

- [ ] **R8 Avoid _onPanelDataChanged for purely cosmetic bumps** — `chat_connection_manager.dart:238,308`. `_updateMessageText` and `fetchChatStatus` bump `chatVersion` for cosmetic text updates (ban stacking, follower-mode text). These don't change message content — only system message text. Fix: use a separate `ValueNotifier` for status bar text and system message mutations.
