# PLAN.md

## Bugs

| # | Status | Severity | File | Issue |
|---|--------|----------|------|-------|
| 1 | ✅ done | HIGH | `twitch_badge_service.dart:62` | `clearChannel()` defined but never called. Badge data accumulates per channel forever. |
| 2 | | HIGH | `home_screen.dart:348-369` | `_onInputChanged()` has no debounce — `filterSuggestions` iterates 5000 users + 500 emotes per keystroke. `_autocompleteTimer` field at line 169 is declared but never wired up. |
| 3 | ✅ done | MEDIUM | `emote_manager.dart` | No `dispose()` override. `ChangeNotifier` listener list never formally cleared. |
| 4 | | LOW | `home_screen.dart` | `_suggestionsNotifier` (line 168) and `_channelNotifier` (line 146) not disposed. |
| 5 | | LOW | `twitch_badge_service.dart` | `_channelAvatars`, `_channelNames` never cleaned up (only accumulated, no removal). |

## Optimizations

| # | Status | Severity | File | Lines | Issue |
|---|--------|----------|------|-------|-------|
| 6 | | HIGH | `chat_connection_manager.dart` | 856, 1018 | `truncateChannelMessages` O(n) called per incoming message — builds reply graph + BFS every time. Should use simple `removeRange` for minor overflow and full algorithm only when threshold exceeded. |
| 7 | | HIGH | `home_screen.dart` | 403-411 | `_computeThreadMessages()` runs on every message while thread panel is open despite only needing recomputation when a new message joins the specific thread. |
| 8 | | MEDIUM | `chat_connection_manager.dart` | 876, 1022 | `precacheMessageEmotes` called on every message — splits text by whitespace, map lookups per word, queues async downloads. |
| 9 | | MEDIUM | `emote_manager.dart` | 197 | `markEmoteUsed()` calls `notifyListeners()` on every emote send/selection — only the recent list changed, doesn't affect rendering. |
| 10 | | LOW | `chat_connection_manager.dart` | 809-825 | `onMessage()` own-message detection uses `_pendingLocalsByNorm` reconciliation — text-normalization-based dedup could match wrong messages. Edge case. |

## Think about it

(Larger changes that need refactoring — note for future)

- `home_screen.dart`: `ListenableBuilder` wraps entire `TabbedLayout` — every `_chatVersion` bump rebuilds all tabs + pages. Per-channel `ValueNotifier` could scope rebuilds to active channel only.
- `home_screen.dart`: `precacheMessageEmotes` runs on every message, but only visible messages need precaching. Could be limited to messages that reach the `ListView.builder` itemBuilder.
- `emote_manager.dart`: `preloadGlobalEmotes` and `resolveEmotes` each call `_notify()` twice (cached + fresh). Could coalesce into a single notification with a microtask.
