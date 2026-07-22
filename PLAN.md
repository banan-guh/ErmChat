Critical
1. debugPrint on every IRC line (lib/services/twitch_irc.dart:162)
Every single IRC message (user chats, protocol traffic) is printed to stderr. On a busy channel (10-50 msg/s), this is massive I/O overhead. The debugPrint at line 162 prints every raw line, plus additional prints on CLEARCHAT, NOTICE, and ban events.
2. RegExp allocation per message with reply (lib/services/twitch_eventsub.dart:242)
In the hot path for every incoming chat message that has a reply (threads), a new RegExp is constructed and compiled. This can be replaced with String.startsWith() since the prefix character is already known.
High
3. _onEmotesChanged invalidates ALL cached spans (lib/screens/home_screen.dart:354)
Every emote manager notification (emote resolution, 7TV updates, login) iterates every message in every channel and sets msg.cachedSpans = null, then calls setState. This forces recomputation of every message's emote text spans on every emote change.
4. Full-screen setState on every chat message (lib/screens/home_screen.dart)
The onRebuild callback (setState((){})) fires on every incoming message via chatVersion + onRebuild. This rebuilds the entire 1753-line widget tree — including all panels, the autocomplete dropdown, the chat status bar, etc. — even though only one channel's list actually changed.
5. ValueListenableBuilder rebuild cascade (lib/widgets/thread_panel.dart:52, lib/widgets/mentions_panel.dart:39)
The panel widgets create ValueListenableBuilder in their build(), meaning every parent setState creates a fresh builder widget, which re-invokes the builder closure even if the listenable value hasn't changed. This reconstructs all message tiles inside the panel.
6. byCode() allocates new ChannelEmotes every call (lib/services/emote_manager.dart:43-51)
Called in the message rendering hot path (_computeMessageSpans → EmoteText.build). Every call merges global + channel caches into a new map and allocates a sorted list.
7. Slider writes to disk on every drag tick (lib/screens/settings_screen.dart)
The max-messages slider calls SharedPreferences.getInstance() + setInt on every frame during drag. Should defer to onChangeEnd.
8. pubspec.yaml read from disk on every settings build (lib/screens/settings_screen.dart)
Uses a sync File.readAsStringSync() on pubspec.yaml every time the settings screen builds. Never cached.
Medium
9. O(n) scan of pendingLocals on every incoming message (lib/services/chat_connection_manager.dart:773)
onMessage iterates all pending entries to find a match via normalizeForReconciliation. A Map<String, PendingLocal> keyed by normalizeForReconciliation(text) would be O(1).
10. _computeThreadMessages() O(n²) do-while loop (lib/screens/home_screen.dart:1003)
Iterates all channel messages repeatedly until no new additions. For large channels, this is quadratic. A single BFS pass would be O(n).
11. twitchRanges map allocation per message (lib/widgets/emote_text.dart:125-135)
For every message with Twitch emote positions, a Map<int, EmotePosition> is built by iterating each position and filling every character index. This is memory-heavy for messages with many emotes.
12. TextEditingController leak in UserProfileSheet (lib/widgets/user_profile_sheet.dart:255)
The Report dialog's onTap creates a TextEditingController inline without ever disposing it.
13. tabbed_layout.dart allocates all page widgets on every build (lib/widgets/tabbed_layout.dart:191-194)
List.generate calls pageBuilder for every tab on every build, even though only one tab is visible. These are discarded by TabBarView's internal index but still constructed and measured.
14. chatStatus and GlobalKey leak on channel removal (lib/screens/home_screen.dart:738-760)
When removing a channel, _chatStatus[channel] and _messageKeys entries are not cleaned up from the connection manager's maps (which are all passed by reference). These maps grow unboundedly as channels are added/removed.
Low
- home_screen.dart:1649 — itemBuilder creates closures (() => _showMessageMenu(msg), (login, userId) => ...) on every rebuild for every visible item
- chat_connection_manager.dart:148-163 — _markUserMessagesDeleted iterates all messages linearly; fine for bans (rare) but could be optimized with an index
- settings_screen.dart — many setState calls rebuild the entire 500-line tree when smaller StatefulBuilder regions would suffice
- twitch_irc.dart line 162 and chat_connection_manager.dart — excessive debugPrint throughout (on bans, notices, message deletes, etc.)
Recommended approach
The top 3 fixes that would have the most impact:
1. Remove or gate IRC debugPrint — wrap in assert or kDebugMode guard
2. Replace RegExp with startsWith in twitch_eventsub.dart:242
3. Scoped rebuilds — use ValueListenableBuilder / ListenableBuilder at the channel level instead of full-screen setState. Consider RepaintBoundary on per-channel chat lists and panels to isolate rebuilds.