import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';
import '../services/chat_store.dart';
import '../services/saved_threads_store.dart';
import '../services/seven_tv_paint_service.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../third_party/flutter_list_view/flutter_list_view.dart';
import '../util/haptics.dart';
import '../util/thread_utils.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/panel_manager.dart';

// Shell-owned state the thread panels read but do not own.
abstract class ThreadPanelsHost extends ShellState {
  bool isMounted();
  void markDirty();
  void switchChannelTo(int index);
  void showNotice(String text);
  @override
  bool get showTimestamps;
  @override
  String get timestampFormat;
  double get chatFontSize;
  bool get checkeredMessages;
  double get highlightOpacity;
  bool get lineSeparator;
  String get sharedChatMode;
  SevenTvPaintService? get namePaintService;
  void copyMessage(TwitchMessage msg);
}

// Thread view, dashboard, and saved threads: data, open/show verbs,
// and the thread panel builders.
class ThreadPanels {
  ThreadPanels({
    required this.panelManager,
    required this.chatStore,
    required this.threadsTab,
    required this.composer,
    required this.messageBuilder,
    required this.userSheets,
    required this.menus,
    required this.host,
  });

  final PanelManager panelManager;
  final ChatStore chatStore;
  final TabController Function() threadsTab;
  final ComposerController composer;
  final MessageBuilder messageBuilder;
  final UserSheets userSheets;
  final MessageMenus menus;
  final ThreadPanelsHost host;

  final savedThreads = SavedThreadsStore();
  final threadLastSeen = <String, DateTime>{};
  final threadsListVersion = ValueNotifier(0);
  final threadMsgCount = ValueNotifier(0);
  final threadAtBottom = ValueNotifier(true);
  final threadPanelScrollCtrl = FlutterListViewController();

  void dispose() {
    threadsListVersion.dispose();
    threadMsgCount.dispose();
    threadAtBottom.dispose();
    threadPanelScrollCtrl.dispose();
  }

  // Walk the reply-parent chain to the root with cycle detection.
  // A message that has children counts as root even with a parent.
  TwitchMessage? findThreadRoot(TwitchMessage msg) {
    return panelManager.findThreadRoot(
      msg,
      channelMessages: chatStore.channelMessages,
    );
  }

  // Clear the open thread without touching the panel (channel switches,
  // mentions/mod opens).
  void clearOpenThread() => panelManager.openThreadRoot = null;

  // Drop thread state pointing at a departed channel so the Thread tab
  // never renders one that is no longer joined. Saved bookmarks are
  // global and intentionally survive.
  void forgetChannel(String channel) {
    threadLastSeen.removeWhere((k, _) => k.startsWith('$channel:'));
    if (panelManager.openThreadRoot?.channel == channel) {
      panelManager.openThreadRoot = null;
    }
    if (panelManager.openThreadRoot == null) {
      panelManager.threadMessages = [];
    }
    if (panelManager.threadChannel == channel) {
      panelManager.threadChannel = null;
    }
  }

  Future<void> showThreadView(
    TwitchMessage rootMsg, {
    bool switchChannel = true,
  }) async {
    final channel = rootMsg.channel;
    if (channel == null) return;
    await panelManager.closePanel();
    if (!host.isMounted()) {
      return;
    }
    if (switchChannel && host.selectedChannel != channel) {
      final idx = chatStore.channels.indexOf(channel);
      if (idx >= 0) host.switchChannelTo(idx);
    }
    if (!host.isMounted()) return;
    panelManager.activePanel = OverlayPanel.thread;
    panelManager.openThreadRoot = rootMsg;
    host.markDirty();
    panelManager.threadChannel = channel;
    panelManager.threadMessages = computeThreadMessages();
    threadMsgCount.value++;
    final rootId = rootMsg.replyThreadRootId ?? rootMsg.messageId;
    if (rootId != null) {
      threadLastSeen['$channel:$rootId'] = DateTime.now();
      threadsListVersion.value++;
    }
    // Jump, don't animate: the panel opens already on the Thread tab, so an
    // animateTo would flash the strip swiping over from Active/Saved.
    threadsTab().index = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.isMounted()) {
        panelManager.animateRatio(
          panelManager.threadSheetRatio,
          0.0,
          PanelManager.fullHeightFraction,
          PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  // Opens the threads dashboard (Thread | Active | Saved tabs) without
  // dropping a currently open thread: the Thread tab keeps its rows so the
  // dashboard can be browsed and returned from.
  Future<void> showThreadsDashboard({int tab = 1}) async {
    final prevRoot = panelManager.openThreadRoot;
    final prevMsgs = List.of(panelManager.threadMessages);
    final prevChannel = panelManager.threadChannel;
    await panelManager.closePanel();
    if (!host.isMounted()) return;
    composer.unfocus();
    panelManager.activePanel = OverlayPanel.thread;
    host.markDirty();
    // closePanel clears the manager's root; restore the open thread so the
    // Thread tab survives dashboard browsing. Active stays per selected
    // channel; the Thread tab may show another channel's thread.
    panelManager.openThreadRoot = prevRoot;
    panelManager.threadMessages = prevMsgs;
    panelManager.threadChannel =
        prevRoot?.channel ?? prevChannel ?? host.selectedChannel;
    // Same no-flash jump as showThreadView: the sheet opens already on the
    // requested tab.
    threadsTab().index = tab.clamp(0, 2);
    threadsListVersion.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.isMounted()) {
        panelManager.animateRatio(
          panelManager.threadSheetRatio,
          0.0,
          PanelManager.fullHeightFraction,
          PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  Future<void> loadSaved() async {
    try {
      await savedThreads.load();
      syncSavedKeys();
      if (host.isMounted()) threadsListVersion.value++;
    } catch (_) {
      // Corrupt storage never blocks startup; dashboard just starts empty.
    }
  }

  Future<void> persistSaved() async {
    try {
      await savedThreads.flush();
    } catch (_) {
      // Best effort; the in-memory list still works for the session.
    }
  }

  void syncSavedKeys() {
    chatStore.savedThreadKeys
      ..clear()
      ..addAll(savedThreads.keys);
  }

  // Mirror fresh channel history into saved threads carrying that channel.
  void syncSavedWithChannel(String channel) {
    var hasSaved = false;
    for (final t in savedThreads.threads) {
      if (t.channel == channel) {
        hasSaved = true;
        break;
      }
    }
    if (!hasSaved) return;
    final msgs = chatStore.channelMessages[channel];
    if (msgs == null || msgs.isEmpty) return;
    var appended = false;
    for (final m in msgs) {
      if (m.isSystem) continue;
      if (savedThreads.appendMessage(m)) appended = true;
    }
    if (appended) {
      unawaited(persistSaved());
      threadsListVersion.value++;
    }
  }

  // Thread branch of panel data fan-out: refresh the open thread or, with
  // no thread selected, tick the Active list.
  void refreshOnData(String? changedChannel) {
    if (panelManager.activePanel != OverlayPanel.thread) return;
    final openRoot = panelManager.openThreadRoot;
    if (openRoot != null) {
      // Skip recomputation unless the new message belongs to the open
      // thread's channel; the thread only mutates when that channel moves.
      if (changedChannel != null && changedChannel != openRoot.channel) return;
      panelManager.threadChannel = openRoot.channel;
      panelManager.threadMessages
        ..clear()
        ..addAll(computeThreadMessages());
      threadMsgCount.value++;
      // Watching the Thread tab marks it seen so the Active row does not
      // flip back to unread while you stare at it.
      if (threadsTab().index == 0) {
        final channel = openRoot.channel;
        final rootId = openRoot.replyThreadRootId ?? openRoot.messageId;
        if (channel != null && rootId != null) {
          threadLastSeen['$channel:$rootId'] = DateTime.now();
        }
      }
      threadsListVersion.value++;
    } else {
      // Dashboard open without a thread selected: Active still moves.
      if (changedChannel != null &&
          changedChannel != host.selectedChannel &&
          changedChannel != panelManager.threadChannel) {
        return;
      }
      threadsListVersion.value++;
    }
  }

  String? threadRootIdOf(TwitchMessage msg) =>
      msg.replyThreadRootId ?? msg.messageId;

  bool isThreadSaved(TwitchMessage rootMsg) {
    final channel = rootMsg.channel;
    final rootId = threadRootIdOf(rootMsg);
    if (channel == null || rootId == null) return false;
    return savedThreads.isSaved(channel, rootId);
  }

  // Resolves the actual root message for a thread key, so bookmarks snapshot
  // the root's author/text instead of whichever reply got long-pressed.
  TwitchMessage? resolveThreadRootMessage(String channel, String rootId) {
    final indexed = chatStore.threadFor(channel, rootId);
    if (indexed != null) {
      for (final m in indexed) {
        if (m.messageId == rootId) return m;
      }
    }
    final buffered = chatStore.channelMessages[channel];
    if (buffered != null) {
      for (final m in buffered) {
        if (m.messageId == rootId) return m;
      }
    }
    final logged = savedThreads.messagesFor(channel, rootId);
    for (final m in logged) {
      if (m.messageId == rootId) return m;
    }
    return null;
  }

  // Newest message of a thread by timestamp (insertion order is not a sort
  // contract: history batches can arrive out of order).
  TwitchMessage? newestThreadMessage(List<TwitchMessage> msgs) {
    if (msgs.isEmpty) return null;
    var best = msgs.first;
    for (final m in msgs.skip(1)) {
      if (m.timestamp.isAfter(best.timestamp)) best = m;
    }
    return best;
  }

  void toggleSaveThread(TwitchMessage rootMsg) {
    final channel = rootMsg.channel?.toLowerCase();
    final rootId = threadRootIdOf(rootMsg);
    if (channel == null || rootId == null) return;
    final resolved = resolveThreadRootMessage(channel, rootId) ?? rootMsg;
    final willEvict =
        !savedThreads.isSaved(channel, rootId) &&
        savedThreads.threads.length >= maxSavedThreads;
    final fullLog = computeThreadMessagesFor(channel, rootId);
    final saved = savedThreads.toggle(
      SavedThread.fromMessage(resolved, rootId),
      fullLog.isEmpty ? [resolved] : fullLog,
    );
    syncSavedKeys();
    unawaited(persistSaved());
    threadsListVersion.value++;
    if (host.isMounted()) {
      host.markDirty();
      host.showNotice(
        saved
            ? (willEvict ? 'Thread saved (oldest removed)' : 'Thread saved')
            : 'Thread unsaved',
      );
    }
  }

  // Full log for a thread key: live store first, then the persisted log for
  // saved threads (dedup by id, newest-first). Used at save time and by the
  // thread view so saved threads render fully offline.
  List<TwitchMessage> computeThreadMessagesFor(String channel, String rootId) {
    final seen = <String>{};
    final out = <TwitchMessage>[];
    void add(TwitchMessage m) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) return;
      }
      out.add(m);
    }

    final live = chatStore.threadFor(channel, rootId);
    if (live != null) {
      for (final m in live) {
        add(m);
      }
    } else {
      final buffered = chatStore.channelMessages[channel];
      if (buffered != null) {
        final parentOf = <String, String>{};
        for (final m in buffered) {
          if (m.replyToParentId != null && m.messageId != null) {
            parentOf[m.messageId!] = m.replyToParentId!;
          }
        }
        for (final m in buffered) {
          if (threadKeyFor(m, parentOf) == rootId) add(m);
        }
      }
    }
    if (savedThreads.isSaved(channel, rootId)) {
      for (final m in savedThreads.messagesFor(channel, rootId)) {
        add(m);
      }
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  void openActiveThread(ThreadSummary summary, String channel) {
    final msgs = chatStore.threadFor(channel, summary.rootId);
    TwitchMessage? target = summary.root;
    target ??= msgs?.firstOrNull;
    target ??= resolveThreadRootMessage(channel, summary.rootId);
    if (target == null) {
      host.showNotice('Thread no longer available');
      return;
    }
    unawaited(showThreadView(target));
  }

  void openSavedThread(SavedThread entry) {
    // Saved threads open offline: the persisted log renders even when the
    // channel is not joined, and no channel switch happens in that case.
    final joined = chatStore.channels.contains(entry.channel);
    final target =
        resolveThreadRootMessage(entry.channel, entry.rootId) ??
        TwitchMessage(
          login: entry.login.isNotEmpty ? entry.login : 'thread',
          displayName: entry.author.isNotEmpty ? entry.author : entry.login,
          text: '',
          messageId: entry.rootId,
          channel: entry.channel,
        );
    unawaited(showThreadView(target, switchChannel: joined));
  }

  List<TwitchMessage> computeThreadMessages() {
    final live = panelManager.computeThreadMessages(
      openThreadRoot: panelManager.openThreadRoot,
      channelMessages: chatStore.channelMessages,
      threadFor: (ch, rootId) => chatStore.threadFor(ch, rootId),
    );
    // Saved threads merge the persisted full log so the view survives buffer
    // eviction and restarts. Live rows win on id conflicts.
    final root = panelManager.openThreadRoot;
    final channel = root?.channel;
    final rootId = root == null
        ? null
        : (root.replyThreadRootId ?? root.messageId);
    if (channel == null || rootId == null) return live;
    if (!savedThreads.isSaved(channel, rootId)) return live;
    final seen = <String>{};
    final out = <TwitchMessage>[];
    for (final m in live) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) continue;
      }
      out.add(m);
    }
    for (final m in savedThreads.messagesFor(channel, rootId)) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) continue;
      }
      out.add(m);
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  void onThreadsTabChanged() {
    if (threadsTab().indexIsChanging) return;
    iosHaptic(HapticFeedback.selectionClick);
    // Returning to the Thread tab marks the open thread seen so its Active
    // row clears its unread highlight.
    if (threadsTab().index == 0 && panelManager.openThreadRoot != null) {
      final channel = panelManager.openThreadRoot!.channel;
      final rootId =
          panelManager.openThreadRoot!.replyThreadRootId ??
          panelManager.openThreadRoot!.messageId;
      if (channel != null && rootId != null) {
        threadLastSeen['$channel:$rootId'] = DateTime.now();
        threadsListVersion.value++;
      }
    }
    host.markDirty();
  }

  bool isThreadUnread(String channel, ThreadSummary summary) {
    final seen = threadLastSeen['$channel:${summary.rootId}'];
    if (seen == null) return true;
    return summary.lastActivity.isAfter(seen);
  }

  Widget threadPanel(
    BuildContext context, {
    required Widget Function({
      required bool offstage,
      required ValueNotifier<double> ratio,
      required Widget header,
      required Widget body,
    })
    overlaySheet,
    required VoidCallback closePanel,
  }) {
    return overlaySheet(
      offstage: panelManager.activePanel != OverlayPanel.thread,
      ratio: panelManager.threadSheetRatio,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: closePanel,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Threads',
                    style: TextStyle(
                      fontSize: 20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: threadsTab(),
            padding: EdgeInsets.fromLTRB(100.0, 0.0, 100.0, 0.0),
            // Three tabs in the mentions-width island: center the strip so it
            // reads the same, and let it scroll instead of clipping labels on
            // narrow phones.
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: const [
              Tab(text: 'Thread'),
              Tab(text: 'Active'),
              Tab(text: 'Saved'),
            ],
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: TabBarView(
        controller: threadsTab(),
        children: [
          ChatView(
            key: const ValueKey('thread_panel'),
            channel: panelManager.threadChannel ?? '',
            messages: panelManager.threadMessages,
            atBottomNotifier: threadAtBottom,
            messageNotifier: threadMsgCount,
            scrollController: threadPanelScrollCtrl,
            messageBuilder: messageBuilder,
            showTimestamp: host.showTimestamps,
            timestampFormat: host.timestampFormat,
            chatFontScale: host.chatFontSize / 14.0,
            checkeredMessages: host.checkeredMessages,
            highlightOpacity: host.highlightOpacity,
            lineSeparator: host.lineSeparator,
            sharedChatMode: host.sharedChatMode,
            paintService: host.namePaintService,
            onShowUserProfile: (login, userId, {displayName}) =>
                userSheets.showUserProfile(
                  context,
                  login,
                  userId,
                  displayName: displayName,
                ),
            onShowMessageMenu: (msg) =>
                menus.showPanelMessageMenu(context, msg),
            onCopyMessage: host.copyMessage,
            showReplyIndicators: false,
            emptyText: 'No messages found',
          ),
          _activeThreadsList(context),
          _savedThreadsList(context),
        ],
      ),
    );
  }

  Widget _activeThreadsList(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: threadsListVersion,
      builder: (context, _, _) {
        final channel = host.selectedChannel ?? panelManager.threadChannel;
        if (channel == null) {
          return const Center(child: Text('Join a channel to see threads'));
        }
        final threads = chatStore.activeThreads(channel);
        if (threads.isEmpty) {
          return const Center(child: Text('No active threads'));
        }
        final theme = Theme.of(context);
        return ListView.builder(
          itemCount: threads.length,
          itemBuilder: (context, i) {
            final summary = threads[i];
            final unread = isThreadUnread(channel, summary);
            // Orphan threads have no root yet; show the newest reply by
            // timestamp so the row still identifies the conversation.
            final live = chatStore.threadFor(channel, summary.rootId);
            final display =
                summary.root ??
                (live == null ? null : newestThreadMessage(live));
            final author = display != null
                ? (display.displayName.isNotEmpty
                      ? display.displayName
                      : display.login)
                : 'Thread';
            final preview = display != null ? display.text : '';
            final saved = savedThreads.isSaved(channel, summary.rootId);
            return ListTile(
              leading: const Icon(Icons.forum),
              title: Text(
                preview.isEmpty ? author : '$author: $preview',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                  color: unread ? theme.colorScheme.onSurface : null,
                ),
              ),
              subtitle: Text(
                '${summary.replyCount} '
                '${summary.replyCount == 1 ? 'reply' : 'replies'}'
                ' · ${formatTimestamp(summary.lastActivity, host.timestampFormat)}',
              ),
              trailing: display == null
                  ? null
                  : IconButton(
                      icon: Icon(
                        saved ? Icons.bookmark : Icons.bookmark_border,
                      ),
                      tooltip: saved ? 'Unsave thread' : 'Save thread',
                      onPressed: () => toggleSaveThread(display),
                    ),
              onTap: () => openActiveThread(summary, channel),
            );
          },
        );
      },
    );
  }

  Widget _savedThreadsList(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: threadsListVersion,
      builder: (context, _, _) {
        final saved = savedThreads.threads;
        if (saved.isEmpty) {
          return const Center(child: Text('No saved threads yet'));
        }
        return ListView.builder(
          itemCount: saved.length,
          itemBuilder: (context, i) {
            final entry = saved[i];
            return ListTile(
              leading: const Icon(Icons.bookmark),
              title: Text(
                entry.preview.isEmpty
                    ? entry.author
                    : '${entry.author}: ${entry.preview}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('#${entry.channel}'),
              trailing: IconButton(
                icon: const Icon(Icons.bookmark),
                tooltip: 'Unsave thread',
                onPressed: () => unsaveThread(entry),
              ),
              onTap: () => openSavedThread(entry),
            );
          },
        );
      },
    );
  }

  void unsaveThread(SavedThread entry) {
    savedThreads.remove(entry.channel, entry.rootId);
    syncSavedKeys();
    unawaited(persistSaved());
    threadsListVersion.value++;
    if (host.isMounted()) {
      host.markDirty();
      host.showNotice('Thread unsaved');
    }
  }
}
