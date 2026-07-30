# Performance Audit

## Critical (jank-causing)

- [ ] **#1 `insert(0, msg)` O(n) per message** -- `home_screen.dart:673`, `chat_connection_manager.dart:914,1051`. Every incoming message shifts all 200 existing elements right. Busy channels (~3+ msg/s) get continuous O(n) work. Fix: store newest-first (`add()` = amortized O(1)), reverse at display time.

- [ ] **#2 Global `_chatVersion` drives full-tree rebuild** -- `home_screen.dart:1552-1627`. Single `ValueNotifier<int>` bumped on every message/system/emote/status event, rebuilding `TabbedLayout` (all channel tabs + active chat + status bar + overlays). Fix: per-channel notifiers; separate notifier for channel bar vs chat content vs status bar.

- [ ] **#3 `truncateChannelMessages` O(n^2) `removeAt` loop** -- `chat_connection_manager.dart:411-415`. Removes extras by calling `removeAt(i)` in a loop, each call shifts subsequent elements. Fix: build a new retained list in one O(n) pass.

- [ ] **#4 `_findThreadRoot` O(n) scan per message** -- `home_screen.dart:1025-1051`. Called from `ListView.builder` for every message with a `replyToUser`. Each call does two full-list scans. Fix: build a `parentOf` map once and cache; or precompute the thread root at insert time.

- [ ] **#5 `EmoteManager` global `ChangeNotifier` cascading rebuilds** -- `emote_manager.dart` + `emote_menu_panel.dart`. `notifyListeners()` fires for any emote change in any channel during startup, causing ~2+3N async calls (N = channels). Each triggers `_loadRecentEmotes` + `setState`. Fix: dedicated `ValueNotifier` for recent emotes; batch notifications; per-channel notifiers.

## Medium

- [ ] **#6 `_computeThreadMessages` runs on every message even when panels closed** -- `home_screen.dart:520-531`. Builds `parentOf` map + walks all messages + sorts -- O(n log n) per message -- with thread/mentions panels hidden. Fix: guard with `if (_activePanel == OverlayPanel.thread)` checks.

- [ ] **#7 `_onEmotesChanged` clears ALL messages' `cachedSpans`** -- `home_screen.dart:501-518`. Any emote refresh iterates every channel x every message clearing span caches. Fix: per-channel invalidation; use an `emoteVersion` token to skip re-computation.

- [ ] **#8 `Theme.of(context)` + `RegExp` recreated per call** -- `chat_message_tile.dart`, `emote_text.dart:326`, `command_handler.dart:21`. `Theme.of(context)` called 3x in `ChatMessageTile.build()`, `RegExp(r'\s+')` compiled per call in hot paths. Fix: hoist to local variables / `static final` constants.

- [ ] **#9 Manual `ValueListenable` + `setState` in panels** -- `thread_panel.dart:60-77`, `mentions_panel.dart:60-64`. Every data change triggers full widget tree rebuild. Fix: replace with `ValueListenableBuilder` scoped to the content area.

- [ ] **#10 `TapGestureRecognizer` created per build** -- `chat_message_tile.dart:77-86`, `emote_text.dart:341-342`. New recognizer allocated every time a tile/span builds -- 20+ allocations per frame in a 20-visible-item `ListView`. Fix: cache via `StatefulWidget` + `didUpdateWidget`, or use `InkWell`.

## Minor

- [ ] **#11 `_frozenSnapshot` doubles message memory** -- `home_screen.dart:149,2122-2124`. Shallow-copies the entire message list when user scrolls up. Fix: track offset + pre-roll count instead of duplicating the list.

- [ ] **#12 `_userStore` uses `LinkedHashMap<String, void>` with null values** -- `user_store.dart:5,9-15`. Wastes value slot on every entry. Fix: use `LinkedHashSet<String>` from `dart:collection`.

- [ ] **#13 `LayoutBuilder` per emote grid cell** -- `emote_menu_panel.dart:290-305`. Each of ~50 grid items has a `LayoutBuilder` for a simple padding computation. Fix: precompute cell width from grid dimensions and use `Padding` directly.

- [ ] **#14 `command_handler.dart` user ID lookups make HTTP call per command** -- lines 73, 99, 139, 222. `/ban`, `/timeout`, etc. resolve username-to-ID via network every time. Fix: local `Map<String, String>` cache for the session.

## Existing bugs (preserved)

- [x] **1 HIGH** `twitch_badge_service.dart:62` -- `clearChannel()` defined but never called. Badge data accumulates per channel forever.
- [ ] **2 HIGH** `home_screen.dart:348-369` -- `_onInputChanged()` has no debounce -- `filterSuggestions` iterates 5000 users + 500 emotes per keystroke. `_autocompleteTimer` field at line 169 is declared but never wired up.
- [x] **3 MEDIUM** `emote_manager.dart` -- No `dispose()` override. `ChangeNotifier` listener list never formally cleared.
- [ ] **4 LOW** `home_screen.dart` -- `_suggestionsNotifier` (line 168) and `_channelNotifier` (line 146) not disposed.
- [ ] **5 LOW** `twitch_badge_service.dart` -- `_channelAvatars`, `_channelNames` never cleaned up (only accumulated, no removal).
