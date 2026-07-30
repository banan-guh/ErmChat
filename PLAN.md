# Performance Audit

## Critical (jank-causing)

- [x] **#1 `truncateChannelMessages` O(n^2) `removeAt` loop** -- `chat_connection_manager.dart:411-415`. Removes extras by calling `removeAt(i)` in a loop, each call shifts subsequent elements. Fix: build a new retained list in one O(n) pass. Plus fast path: `removeRange` for small overflow and only run thread-aware algorithm when excess > 3.

- [ ] **#2 `_onInputChanged` missing debounce** -- `home_screen.dart:348-369`. Every keystroke iterates 5000 users + 500 emotes with string operations, calls `_checkAutocompleteUndo` (heavy logic for a rare edge case), and triggers autocomplete rebuild. `_autocompleteTimer` field declared at line 169 but never wired. Fix: debounce 150ms, skip `_checkAutocompleteUndo` until after cheap length check, only query users on `@` prefix.

- [x] **#3 `EmoteManager` global `ChangeNotifier` cascading rebuilds** -- `emote_manager.dart` + `emote_menu_panel.dart`. `notifyListeners()` fires for any emote change in any channel during startup, causing ~2+3N async calls (N = channels). Each triggers `_loadRecentEmotes` + `setState`. Fix: dedicated `ValueNotifier` for recent emotes; batch notifications; per-channel notifiers.

- [x] **#4 `filterSuggestions` double-iterates all emotes** -- `suggestion.dart:83-94`. Two separate `for` loops over the same list doing `contains` checks, doubling emote iteration. Fix: single pass with `||`.

- [x] **#5 `parseTextWithLinks` runs on every text segment** -- `emote_text.dart:324-357`. Called for every text segment in every message even when zero URLs present. Falls through full regex match for nothing. Fix: quick `if (!text.contains('.')) return` guard skips 99% of messages.

## Medium

- [ ] **#6 `_onEmotesChanged` clears ALL messages' `cachedSpans`** -- `home_screen.dart:501-518`. Any emote refresh iterates every channel x every message clearing span caches. Fix: per-channel invalidation; use an `emoteVersion` token to skip re-computation.

- [ ] **#7 `_computeThreadMessages` runs on every message even when panels closed** -- `home_screen.dart:520-531`. Builds `parentOf` map + walks all messages + sorts -- O(n log n) per message -- with thread/mentions panels hidden. Fix: guard with `if (_activePanel == OverlayPanel.thread)` checks.

- [ ] **#8 `Theme.of(context)` + `RegExp` recreated per call** -- `chat_message_tile.dart`, `emote_text.dart:326`, `command_handler.dart:21`. `Theme.of(context)` called 3x in `ChatMessageTile.build()`, `RegExp(r'\s+')` compiled per call in hot paths. Fix: hoist to local variables / `static final` constants.

- [ ] **#9 `CachedNetworkImage` per badge per message** -- `home_screen.dart:2018-2100`. Every message rebuild creates fresh `CachedNetworkImage` widgets for each badge (400-600 per full rebuild). Fix: extract reusable `BadgeWidget`, wrap in `RepaintBoundary`.

- [x] **#10 Both overlay panels always in tree** -- `home_screen.dart:1634-1790`. Thread sheet and mentions sheet widget trees always built and laid out behind `IgnorePointer`. Fix: use `Offstage` or conditional mounting.

- [ ] **#11 `markEmoteUsed` does SharedPreferences I/O on user tap** -- `emote_manager.dart:167-176`. Every emote click triggers SharedPrefs read + write + JSON encode + `_notify()` (~5-50ms I/O on user interaction). Fix: debounce writes, keep in-memory cache, skip `_notify()`.

- [x] **#12 Manual `ValueListenable` + `setState` in panels** -- `thread_panel.dart:60-77`, `mentions_panel.dart:60-64`. Every data change triggers full widget tree rebuild. Fix: replace with `ValueListenableBuilder` scoped to the content area.

- [ ] **#13 `TapGestureRecognizer` created per build** -- `chat_message_tile.dart:77-86`, `emote_text.dart:341-342`. New recognizer allocated every time a tile/span builds -- 20+ allocations per frame in a 20-visible-item `ListView`. Fix: cache via `StatefulWidget` + `didUpdateWidget`, or use `InkWell`.

## Minor

- [ ] **#14 `_frozenSnapshot` doubles message memory** -- `home_screen.dart:149,2122-2124`. Shallow-copies the entire message list when user scrolls up. Fix: track offset + pre-roll count instead of duplicating the list.

- [x] **#15 `_userStore` uses `LinkedHashMap<String, void>` with null values** -- `user_store.dart:5,9-15`. Wastes value slot on every entry. Fix: use `LinkedHashSet<String>` from `dart:collection`.

- [x] **#16 `LayoutBuilder` per emote grid cell** -- `emote_menu_panel.dart:290-305`. Each of ~50 grid items has a `LayoutBuilder` for a simple padding computation. Fix: precompute cell width from grid dimensions and use `Padding` directly.

- [x] **#17 `command_handler.dart` user ID lookups make HTTP call per command** -- lines 73, 99, 139, 222. `/ban`, `/timeout`, etc. resolve username-to-ID via network every time. Fix: local `Map<String, String>` cache for the session.

- [x] **#18 `isMention` duplicated in two files with regex split** -- `home_screen.dart:2240-2247`, `chat_connection_manager.dart:1083-1090`. Same function defined twice, each uses regex split allocating intermediate strings. Fix: single canonical copy, manual char iteration.

## Existing bugs (preserved)

- [x] **1 HIGH** `twitch_badge_service.dart:62` -- `clearChannel()` defined but never called. Badge data accumulates per channel forever.
- [ ] **2 HIGH** `home_screen.dart:348-369` -- `_onInputChanged()` has no debounce -- `filterSuggestions` iterates 5000 users + 500 emotes per keystroke. `_autocompleteTimer` field at line 169 is declared but never wired up.
- [x] **3 MEDIUM** `emote_manager.dart` -- No `dispose()` override. `ChangeNotifier` listener list never formally cleared.
- [ ] **4 LOW** `home_screen.dart` -- `_suggestionsNotifier` (line 168) and `_channelNotifier` (line 146) not disposed.
- [ ] **5 LOW** `twitch_badge_service.dart` -- `_channelAvatars`, `_channelNames` never cleaned up (only accumulated, no removal).

## Rebuild Scope Optimization

Focus: making each rebuild cheaper/faster rather than preventing rebuilds from being called.

- [x] **R1 Per-channel chat version notifier (high impact)** — `home_screen.dart:149,1591-1666`. A single `_chatVersion` listener wraps the entire `TabbedLayout`. Every message arrival calls `pageBuilder` for ALL channels (`tabbed_layout.dart:237-240`). Fix: give each channel its own `ValueNotifier<int>`; `_buildChat` returns a `ListenableBuilder` listening only to its own channel's notifier. Remove `_chatVersion` from the outer wrapper. Pass `void Function(String channel) bumpChannel` callback to `ChatConnectionManager`.

- [x] **R2 Per-message keys + RepaintBoundary in ListView** — `home_screen.dart:2182-2218`. `ListView.builder.itemBuilder` has no `key` on items, so every rebuild creates new `ChatMessageTile` widgets for all visible messages. Fix: add `key: ValueKey(msg.messageId)` to each `ChatMessageTile` and wrap in `RepaintBoundary` so Flutter can match old/new widgets and skip repainting unchanged tiles.

- [-] **R3 Decouple scroll state from _chatVersion** — `home_screen.dart:2156-2168`. Scroll-up/down bumps `_chatVersion` just to toggle the FAB, cascading into full panel data recalculation. Fix: make `_isAtBottom` a `ValueNotifier<bool>` per channel; FAB visibility driven by `ValueListenableBuilder`. Reverted — frozen snapshot always changes alongside scroll state, so decoupled FAB notifier never fires independently.

- [x] **R4 Lazy panel data computation** — `home_screen.dart:536-547`. `_onPanelDataChanged` runs on every `_chatVersion` bump iterating all messages, even when thread/mentions panels are closed. Fix: early return `if (_activePanel == OverlayPanel.closed) return;` at the top. Or move the listener registration to panel-open time.

- [x] **R5 Hoist Theme.of/MediaQuery outside ListView builder** — `home_screen.dart:2143-2144`. `Theme.of(context).colorScheme.surface`, `MediaQuery.textScalerOf(context).scale(1.0)`, and `s` are computed once per `_buildChat` call but captured in the `itemBuilder` closure anyway. Fix: already hoisted to local vars — verify no redundant calls in `itemBuilder`.

- [-] **R6 Cache expensive closures passed to ChatMessageTile** — `home_screen.dart:2192-2193`. `_buildBadgeSpans` and `_buildMessageSpans` are re-created as closures every `_buildChat` call. While Dart caches tear-offs for static methods, these instance methods with `badgeScale` default parameters may allocate new closures. Fix: verify closure identity; if not tear-offs, extract to method tear-offs (`_buildBadgeSpans` without closure wrapper).

- [-] **R7 Reduce badge widget allocation per message** — `home_screen.dart:2066-2076`. `_buildBadgeSpans` creates a fresh `CachedNetworkImage` per badge per rebuild. With 400-600 badges visible in a full rebuild, this is significant. Fix: extract a `BadgeWidget` with `const`-style caching; wrap in `RepaintBoundary`.

- [-] **R8 Avoid _onPanelDataChanged for purely cosmetic bumps** — `chat_connection_manager.dart:238,308`. `_updateMessageText` and `fetchChatStatus` bump `chatVersion` for cosmetic text updates (ban stacking, follower-mode text). These don't change message content — only system message text. Fix: use a separate `ValueNotifier` for status bar text and system message mutations.

# Code Quality Audit

## Duplicate code

- [x] **C1 `isMention()` defined in two files** -- Fixed: moved to `lib/util/mention.dart`.

- [x] **C2 IRC tag unescaping same logic twice** -- Fixed: moved to `lib/util/irc_utils.dart`.

- [x] **C3 Thread-root chain walking in 3 places** -- Fixed: moved to `lib/util/thread_utils.dart`.

- [x] **C4 IRC ban handler vs EventSub ban handler near-identical** -- Fixed: extracted `_handleBanEvent` in `chat_connection_manager.dart`.

- [ ] **C5 Channel join dialog duplicated** -- `home_screen.dart:900-933`, `channel_settings_screen.dart:38-75`. Same `AlertDialog` + `TextField` + autofocus + onSubmitted pattern. Fix: shared dialog widget.

- [ ] **C6 `_onChannelChanged` vs `_onChannelFocusChanged` nearly identical** -- `home_screen.dart:1418,1437`. Same logic: check if selected, close panel, clear state, update index. One wraps `setState`, other does not. Fix: merge or have one call the other.

## Error handling

- [x] **C7 18 bare `catch (_) {}` blocks** -- Fixed: added `debugPrint` to all 18 blocks across 8 files.

- [x] **C8 `unawaited` futures with unhandled errors** -- Fixed: added `.catchError` to fire-and-forget `loadUserTwitchEmotes` calls. Connection futures already had internal error handling.

## Design

- [ ] **C9 Manual `mounted` flag in `ChatConnectionManager`** -- `chat_connection_manager.dart:70`. Not a `State` subclass, so `mounted` is a hand-rolled bool starting `true`, checked in 12 places, only set to `false` on `dispose()`. Widget could be gone long before dispose runs. Fix: use `isDisposed` flag or remove checks if not needed.

- [ ] **C10 `ChatConnectionManager` takes 30+ callback closures** -- `home_screen.dart:78-129`. Stategist anti-pattern: state duct-taped through closures into a 1092-line class that directly mutates collections passed by reference. Fix: proper separation with dedicated event classes or a reactive state holder.

- [ ] **C11 `SharedPreferences.getInstance()` not injected** -- Called in 8+ places across `home_screen.dart`, `emote_manager.dart`, `chat_settings_screen.dart`, `account_screen.dart`. Each call hits disk. Fix: inject single instance via constructor.

- [ ] **C12 `.then()/.catchError()` mixed with `async/await`** -- `main.dart:51-57`, `home_screen.dart:305-364,850-882`. Two async patterns used inconsistently. Fix: unify on `async/await` with try/catch. **(skip — cosmetic, no bugs)**

- [x] **C13 Mutable static state in `TwitchApi`** -- Fixed: all fields and methods converted to instance-level.

- [ ] **C14 Side effect in getter `EmoteManager.changedChannel`** -- `emote_manager.dart:52-56`. Getter mutates `_changedChannel = null`. Second read returns different result. Fix: rename to `consumeChangedChannel()` or use method.

- [x] **C15 `TwitchMessage.bodyColor` always returns null** -- Fixed: removed getter and the dead branches in `ChatMessageTile`.

## Safety

- [ ] **C16 100+ null assertions (`!`), some double** -- `chat_connection_manager.dart:765` `result.meta!.firstMessageId!`, many others. One unexpected `null` = crash. Fix: prefer local variable with null check + early return over force-unwrap.

- [ ] **C17 Bare `as Map / as List / as String` casts in JSON deserialization** -- `twitch_api.dart` and elsewhere. If Twitch API response shape changes, runtime `TypeError`. Fix: validate with `json_serializable`, `freezed`, or manual checks.

- [ ] **C18 `StreamController.broadcast(sync: true)` risk of re-entrancy** -- `twitch_eventsub.dart:31-51`, `twitch_irc.dart:28`, `twitch_irc_read.dart:6`, `seven_tv_event_client.dart`. Listeners fire synchronously during event dispatch, can cause stack overflows or build() calls during dispatch. Fix: use `sync: false` or document why sync is required.

## Complexity

- [ ] **C19 `connect()` method 189 lines** -- `chat_connection_manager.dart:679-868`. Nested try/finally, 8+ stream subscriptions, near-duplicate IRC and EventSub ban handlers. Fix: extract ban handler, split connection setup per service.

- [ ] **C20 `truncateChannelMessages()` 107-line 5-phase algorithm** -- `chat_connection_manager.dart:311-418`. Rebuilds parent-of maps and walks chains for a simple cap-at-200. Fast-path `removeRange` handles 99% of calls. Fix: fast path first, full algorithm only on large overflow. **(skip — fast path already covers 99%, low impact)**

- [ ] **C21 `_buildSegments` state machine in emote_text.dart** -- `emote_text.dart:138-224`. Character-by-character parser with closure mutating outer scope, three tracking variables, multiple flush calls. Fix: simplify with indexed word splitting or pre-parsed segment list. **(skip — works correctly, risky rewrite of rendering hot path)**

## Observability

- [ ] **C22 62 `debugPrint()` calls instead of structured logging** -- Throughout `lib/`. No log levels, no categories, no filtering, no release-mode elimination. Fix: use `package:logging` or `package:talker`. **(skip — overkill for single-dev project; debugPrint is standard Flutter practice)**

- [ ] **C23 Inconsistent logging format** -- `[ChatConn]`, `[HomeScreen]`, `[7TV]`, `[EmoteText.build]`, `[$debugPrefix]`, `Twitch parsed...`, `Badge fetch failed...`. No consistent prefix convention. Fix: adopt uniform format like `[ClassName] message`. **(skip — only matters if C22 is done; alone, cosmetic)**

## Circular dependencies

- [ ] **C24 Circular dependency between services and widgets** -- `twitch_oauth.dart:6` imports `login_webview.dart`, and `login_webview.dart:3` imports `twitch_oauth.dart`. A service layer importing a widget breaks layered architecture. Fix: invert the dependency -- pass a callback or use a shared event channel.

## File organization

- [ ] **C25 `widget_test.dart` at 2,313 lines** -- `test/widgets/widget_test.dart`. Tests everything (home screen, settings, channel bar, reply threads, system messages, autocomplete, emote menu) in a single file with inline fake services. Fix: split into one file per widget/feature.

- [ ] **C26 `home_screen.dart` still 2,294 lines** -- `lib/screens/home_screen.dart`. Despite refactoring, still excessively long. Fix: continue extraction -- chat builder, overlay builder, panel builders could be separate files.

- [ ] **C27 `chat_connection_manager.dart` has 38+ constructor parameters** -- `lib/services/chat_connection_manager.dart:108-148`. 6 service objects, 13 mutable state maps/sets passed by reference, 12 callbacks, 2 ValueNotifiers. Worse than C10's original count. Fix: builder pattern, DI container, or dedicated configuration object.

- [ ] **C28 No barrel exports** -- No `lib/widgets/widgets.dart` or `lib/services/services.dart`. Every consumer imports individual files by name. Fix: add barrel files for clean public API surfaces. **(skip — modern Dart IDEs handle imports fine; barrels add circular-dep risk)**

## Test quality

- [ ] **C29 `_e()` test helper duplicated** -- `test/unit/emote_text_test.dart:12` and `test/unit/emote_manager_test.dart:5`. Same 13-line helper function for creating test emotes. Fix: extract to shared `test/helpers.dart` or similar.

- [ ] **C30 Channel join sequence repeated ~20x in widget tests** -- `test/widgets/widget_test.dart`. The tap-Add, enterText, tap-Join, pump pattern is copy-pasted throughout. A shared `joinChannel()` helper exists for some groups (line 1201) but not all. Fix: use the helper everywhere or extract a test utility.

- [ ] **C31 Vague test names** -- `test/data/twitch_eventsub_test.dart:117,483-502`. Tests named `'does not crash'` assert nothing about actual behavior. Fix: name tests by what behavior is verified. **(skip — nice-to-have while editing, not worth a pass on its own)**

## Configuration

- [ ] **C32 `analysis_options.yaml` minimal** -- Only includes `package:flutter_lints/flutter.yaml`. Useful rules not enabled: `prefer_const_constructors`, `prefer_final_locals`, `avoid_catches_without_on_clauses`, `require_trailing_commas`, `use_super_parameters`. Fix: add project-specific lint rules. **(skip — would cascade 100+ new warnings; noisy, low reward)**

- [ ] **C33 `TwitchConfig.clientSecret` is dead config** -- `lib/twitch_config.dart:13`. Empty string constant never referenced anywhere. Fix: remove.

- [ ] **C34 Enum serialized by ordinal index** -- `lib/models/generic_emote.dart:52,55`. `EmoteType.values[json['type'] as int]` and `EmoteScope.values[json['scope'] as int? ?? 0]` break if enum order changes. Any persisted data corrupts on reorder. Fix: serialize by name (`name`) or add explicit index field.

- [ ] **C35 Duplicated comment in `twitch_config.dart`** -- `lib/twitch_config.dart:16-24`. Same paragraph about redirect URI appears twice verbatim. Fix: remove duplicate.

- [ ] **C36 `// ignore` comments in test code** -- `test/unit/seven_tv_event_client_test.dart:19,22,24,26`. Four `// ignore: use_null_aware_elements` suppressions suggest the code fights the linter. Fix: use null-aware elements instead of suppressing.

## Magic numbers / strings

- [ ] **C37 Unnamed numeric constants across codebase** -- `200` (max messages), `100` (max recent emotes), `5000` (max users per channel), `2000` (max seen emote IDs), `8` (reconnect attempts), `10` (ban dedup window seconds), `60` (reply preview truncation), `15` (Twitch colors), `0.35` (deleted opacity), `0.6` (emote panel fraction), `250`/`180` (animation ms), `40` (tab bar height), `28.0` (emote base size), `3x` (emote scale factor), `1 << 8` (zero-width flag). Fix: extract to named constants. **(skip — 15+ numbers across 20+ files; works fine as-is, effort outweighs benefit)**

- [ ] **C38 Duplicated reconnect jitter logic** -- `base_irc_connection.dart:208`, `twitch_eventsub.dart:161`, `seven_tv_event_client.dart:396`. Same `0.75 + Random().nextDouble() * 0.5` formula in 3 files. Fix: shared utility function.

- [ ] **C39 `const Duration(seconds: 10)` in 6+ files** -- `twitch_emotes.dart`, `bttv_emotes.dart`, `ffz_emotes.dart`, `seven_tv_emotes.dart`, `recent_messages.dart`, `twitch_api.dart`. Same timeout value duplicated. Fix: shared constant.

## Missing cleanup

- [ ] **C40 `EmoteManager` has no `dispose()`** -- `lib/services/emote_manager.dart:19`. `ChangeNotifier` subclass with no dispose override. Listeners never formally cleared, potential memory leak. (Mentioned in C3 bugs but worth re-flagging here.)

- [ ] **C41 `login_webview.dart` empty `dispose()`** -- `lib/widgets/login_webview.dart:120-123`. `WebViewController` (`_controller`) never cleaned up. Fix: call `_controller?.dispose()` or verify it's self-cleaning.

- [ ] **C42 `SevenTvEventClient.dispose()` only sets flag** -- `seven_tv_event_client.dart`. Sets `_disposed = true` but `_channel`, `_connectivity` references remain. Fix: null out references after disposal.

## Stale / dead code

- [ ] **C43 `_SwipePhysics` class is a no-op** -- `lib/widgets/tabbed_layout.dart:4-15`. Extends `PageScrollPhysics` but overrides no methods. The commented-out overrides (lines 12-17) suggest it was meant to customize fling, but never finished. Fix: remove class and inline `PageScrollPhysics` usage.

- [ ] **C44 Commented-out code in `tabbed_layout.dart`** -- `lib/widgets/tabbed_layout.dart:12-17`. Fling distance/velocity overrides commented out with no explanation of when to restore. Fix: remove or add a TODO with reason.

## Naming

- [ ] **C45 Inconsistent provider class naming** -- `BttvEmoteProvider` vs `FfzEmoteProvider` vs `SevenTvEmoteProvider`. `BTTVEmoteProvider` / `FFZEmoteProvider` / `SevenTVEmoteProvider` would be more consistent. Also `EmoteType.sevenTv` uses lowercase `Tv`. Fix: normalize acronym casing. **(skip — cosmetic rename of 4+ classes with import changes everywhere; zero behavioral change)**

- [ ] **C46 Single-letter variable names in production code** -- `s` for textScale (`chat_message_tile.dart:39`, `emote_text.dart:24`), `d` for message data (`seven_tv_event_client.dart:233`), `ch` for WebSocket channel (`base_irc_connection.dart:53`). Fix: descriptive names. **(skip — cosmetic, no bug risk, standard in hot-path rendering code)**

- [ ] **C47 `IrcReadService.debugPrefix` contains a space** -- `lib/services/twitch_irc_read.dart:13`. `String get debugPrefix => 'IRC read'`. Having a space in what acts as an identifier-like string is unusual and breaks consistent log formatting. Fix: `'IrcRead'` to match class name convention. **(skip — irrelevant unless C22 is done; alone, cosmetic)**

## Import style

- [ ] **C48 Mix of relative and package imports** -- Internal files use relative imports (`'../models/...'`), test files use `package:ermchat/...`, `main.dart` uses bare `'screens/...'`. No consistent convention. Fix: adopt one style project-wide (Flutter team recommends relative for lib/, package for test/). **(skip — pure style choice, massive churn to normalize, no behavioral change)**

- [ ] **C49 Import ordering inconsistency** -- `home_screen.dart:25` imports `package:cached_network_image` after 22 relative imports. Fix: group external packages first, then internal relative imports. **(skip — needs automated formatter pass; no behavioral impact)**

## Unused / borderline imports

- [ ] **C50 `twitch_message.dart` imports `package:flutter/material.dart`** -- `lib/models/twitch_message.dart:1`. Only uses `Color?` which comes from `dart:ui` (re-exported by `material.dart`). Fix: import `dart:ui` or `package:flutter/painting.dart` instead. **(skip — minor import pedantry; works fine via re-export)**
