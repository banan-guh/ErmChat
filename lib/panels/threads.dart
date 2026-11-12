import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/channel/threads.dart';
import '../chat/chat.dart';
import '../composer/composer_controller.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../services/archive_reader.dart';
import '../services/archive_store.dart';
import '../services/saved_threads_store.dart';
import '../util/log.dart';
import '../widgets/seven_tv_paint_service.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../util/thread_utils.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/panel_manager.dart';
import '../widgets/tab_drag_focus.dart';
import '../widgets/thread_graph.dart' as thread_graph;
import '../widgets/island_metrics.dart';

// Thread view, dashboard, and saved threads: data, open/show verbs,
// and the thread panel builders.
class ThreadPanels {
  ThreadPanels({
    required this.panelManager,
    required this.chat,
    required this.threadsTab,
    required this.composer,
    required this.messageBuilder,
    required this.userSheets,
    required this.menus,
    required this.selectedChannel,
    required this.isMounted,
    required this.markDirty,
    required this.switchChannelTo,
    required this.showNotice,
    required this.showTimestamps,
    required this.timestampFormat,
    required this.chatFontSize,
    required this.checkeredMessages,
    required this.highlightOpacity,
    required this.lineSeparator,
    required this.sharedChatMode,
    required this.namePaintService,
    required this.copyMessage,
    required this.strings,
    this.archiveReader,
    Future<ArchiveStore?>? archiveStore,
  }) : savedThreads = SavedThreadsStore(store: archiveStore) {
    panelManager.onOpenThreadChanged = syncPinnedThread;
  }

  final PanelManager panelManager;
  final Chat chat;
  final TabController Function() threadsTab;
  final ComposerController composer;
  final MessageBuilder messageBuilder;
  final UserSheets userSheets;
  final MessageMenus menus;
  final String? Function() selectedChannel;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final void Function(int index) switchChannelTo;
  final void Function(String text) showNotice;
  final bool Function() showTimestamps;
  final String Function() timestampFormat;
  final double Function() chatFontSize;
  final bool Function() checkeredMessages;
  final double Function() highlightOpacity;
  final bool Function() lineSeparator;
  final String Function() sharedChatMode;
  final SevenTvPaintService? Function() namePaintService;
  final void Function(TwitchMessage msg) copyMessage;

  /// Strings in the app language for notices raised outside a build.
  final AppLocalizations Function() strings;

  final SavedThreadsStore savedThreads;

  /// The archive's thread index, when the archive opened.
  final ArchiveReader? archiveReader;

  /// Active threads read from the archive, with the channel they cover.
  List<ArchivedThreadRow> _archiveActive = const [];
  String? _archiveActiveChannel;
  bool _archiveActiveLoading = false;
  bool _archiveActiveReady = false;
  bool _archiveActiveDirty = false;

  /// Replies of the open thread read from the archive, oldest first, keyed
  /// by channel and root id.
  String? _archivedThreadKey;
  List<TwitchMessage> _archivedThreadRows = const [];
  int _archivedThreadLoad = 0;

  static const activeThreadWindow = Duration(hours: 24);
  static const activeThreadLimit = 50;

  final threadLastSeen = <String, DateTime>{};
  final threadsListVersion = ValueNotifier(0);
  final threadMsgCount = ValueNotifier(0);
  final threadAtBottom = ValueNotifier(true);
  final threadPanelScrollCtrl = ScrollController();

  /// Root of the thread the Thread tab rows belong to. Outlives
  /// [PanelManager.openThreadRoot], which panel closes and channel switches
  /// clear so main-chat sends never reply into a thread; the dashboard
  /// restores it so the tab replies to the thread it shows.
  TwitchMessage? _lastThreadRoot;

  /// Bumped when a show verb reopens the sheet. The tab view stays built
  /// while closed and would slide to a new index, so it remounts on the
  /// target tab instead.
  int _openCount = 0;

  /// Half-drag focus: crossings report at 50% via [_onThreadsFocus],
  /// settle syncs through [onThreadsTabChanged].
  late final tabDragFocus = TabDragFocus(
    tab: threadsTab,
    onFocusChanged: _onThreadsFocus,
  );

  /// Composer gating reads this so reply unlocks at the 50% crossing.
  int get effectiveThreadsTab => tabDragFocus.effectiveIndex;

  /// Panel close hook: drop a stranded drag focus.
  void onThreadsClosed() => tabDragFocus.reset();

  void dispose() {
    tabDragFocus.dispose();
    threadsListVersion.dispose();
    threadMsgCount.dispose();
    threadAtBottom.dispose();
    threadPanelScrollCtrl.dispose();
  }

  // Walk the reply-parent chain to the root with cycle detection.
  // A message that has children counts as root even with a parent.
  TwitchMessage? findThreadRoot(TwitchMessage msg) {
    return thread_graph.findThreadRoot(
      msg,
      messagesFor: (c) => chat.channelFor(c)?.messages.items,
    );
  }

  // Clear the open thread without touching the panel (channel switches,
  // mentions/mod opens).
  void clearOpenThread() => panelManager.openThreadRoot = null;

  // Holds the on-screen thread in the store; releases when none is open.
  // Follows every openThreadRoot assignment via PanelManager.
  void syncPinnedThread() {
    for (final name in chat.names) {
      chat.channelFor(name)?.threads.clearPinned();
    }
    final root = panelManager.openThreadRoot;
    final channel = root?.channel;
    final id = root == null ? null : (root.replyThreadRootId ?? root.messageId);
    if (channel != null && id != null) {
      chat.channelFor(channel)?.threads.pin(id);
    }
  }

  // Drop thread state pointing at a departed channel so the Thread tab
  // never renders one that is no longer joined. Saved bookmarks are
  // global and intentionally survive.
  void forgetChannel(String channel) {
    threadLastSeen.removeWhere((k, _) => k.startsWith('$channel:'));
    _syncedHead.remove(channel);
    if (panelManager.openThreadRoot?.channel == channel) {
      panelManager.openThreadRoot = null;
    }
    if (_lastThreadRoot?.channel == channel) _lastThreadRoot = null;
    if (_lastThreadRoot == null) {
      _setThreadRows(const []);
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
    // Picking a thread from the open dashboard swaps it in place; the sheet
    // only closes and reopens when it was closed or the channel changes.
    final inPlace =
        panelManager.activePanel == OverlayPanel.thread &&
        !panelManager.emoteSheetOpen &&
        (!switchChannel || selectedChannel() == channel);
    if (!inPlace) {
      await panelManager.closePanel();
      if (!isMounted()) return;
    }
    tabDragFocus.reset();
    if (switchChannel && selectedChannel() != channel) {
      final idx = chat.names.indexOf(channel);
      if (idx >= 0) switchChannelTo(idx);
    }
    if (!isMounted()) return;
    panelManager.activePanel = OverlayPanel.thread;
    panelManager.openThreadRoot = rootMsg;
    _lastThreadRoot = rootMsg;
    markDirty();
    panelManager.threadChannel = channel;
    _setThreadRows(computeThreadMessages());
    threadMsgCount.value++;
    unawaited(_loadArchivedThread(force: true));
    final rootId = rootMsg.replyThreadRootId ?? rootMsg.messageId;
    if (rootId != null) {
      threadLastSeen['$channel:$rootId'] = DateTime.now();
      threadsListVersion.value++;
    }
    // Jump, don't animate: the panel opens already on the Thread tab, so an
    // animateTo would flash the strip swiping over from Active/Saved.
    // jumpTo (not a bare index set) so the warp swallows travel updates.
    if (!inPlace) _openCount++;
    tabDragFocus.jumpTo(0);
    if (inPlace) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted()) {
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
    // A closed panel already dropped its root; the last thread still owns
    // the rows the Thread tab shows.
    final wasOpen = panelManager.openThreadRoot != null;
    final prevRoot = panelManager.openThreadRoot ?? _lastThreadRoot;
    final prevMsgs = List.of(panelManager.threadMessages);
    final prevChannel = panelManager.threadChannel;
    await panelManager.closePanel();
    if (!isMounted()) return;
    tabDragFocus.reset();
    composer.unfocus();
    panelManager.activePanel = OverlayPanel.thread;
    markDirty();
    // closePanel clears the manager's root; restore the open thread so the
    // Thread tab survives dashboard browsing. Active stays per selected
    // channel; the Thread tab may show another channel's thread.
    panelManager.openThreadRoot = prevRoot;
    _setThreadRows(prevMsgs);
    if (!wasOpen && prevRoot != null) {
      // Rows froze while the panel was closed; catch up on missed replies,
      // keeping the old rows if the buffer already forgot the thread.
      final fresh = computeThreadMessages();
      if (fresh.isNotEmpty) _setThreadRows(fresh);
    }
    panelManager.threadChannel =
        prevRoot?.channel ?? prevChannel ?? selectedChannel();
    if (prevRoot != null && prevRoot.channel != null) {
      unawaited(_loadArchivedThread());
    }
    if (tab.clamp(0, 2) == 1) _loadActiveThreads();
    // Same no-flash jump as showThreadView: the sheet opens already on the
    // requested tab. jumpTo (not a bare index set) so the warp swallows
    // travel updates.
    _openCount++;
    tabDragFocus.jumpTo(tab.clamp(0, 2));
    threadsListVersion.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted()) {
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
      if (isMounted()) threadsListVersion.value++;
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
    final globalKeys = savedThreads.keys;
    for (final name in chat.names) {
      chat.channelFor(name)?.threads.syncSavedKeys(name, globalKeys);
    }
  }

  /// Newest buffer row already mirrored per channel, so live bumps walk only
  /// the rows above it.
  final Map<String, TwitchMessage> _syncedHead = {};

  // Mirror fresh channel rows into saved threads carrying that channel.
  // [newOnly] stops at the last mirrored head (live inserts land on top);
  // history merges insert mid-buffer, so they pass false for a full pass.
  void syncSavedWithChannel(String channel, {bool newOnly = false}) {
    if (!savedThreads.hasChannel(channel)) {
      _syncedHead.remove(channel);
      return;
    }
    final msgs = chat.channelFor(channel)?.messages.items;
    if (msgs == null || msgs.isEmpty) return;
    final head = newOnly ? _syncedHead[channel] : null;
    _syncedHead[channel] = msgs.first;
    var appended = false;
    for (final m in msgs) {
      if (identical(m, head)) break;
      if (m.isSystem) continue;
      if (savedThreads.appendMessage(m)) appended = true;
    }
    if (appended) {
      unawaited(persistSaved());
      threadsListVersion.value++;
    }
  }

  /// Reads the Active tab's roots from the archive, then merges them with the
  /// live buffer. A read in flight keeps the request pending, so a burst of
  /// messages costs one more query, not one each.
  void _loadActiveThreads() {
    final channel = selectedChannel() ?? panelManager.threadChannel;
    if (channel == null) return;
    final reader = archiveReader;
    if (reader == null) {
      _archiveActive = const [];
      _archiveActiveChannel = channel;
      _archiveActiveReady = true;
      threadsListVersion.value++;
      return;
    }
    if (_archiveActiveLoading) {
      _archiveActiveDirty = true;
      return;
    }
    _archiveActiveLoading = true;
    _archiveActiveReady = false;
    _archiveActiveChannel = channel;
    threadsListVersion.value++;
    unawaited(_fetchActiveThreads(channel, reader));
  }

  Future<void> _fetchActiveThreads(String channel, ArchiveReader reader) async {
    var threads = <ArchivedThreadRow>[];
    try {
      threads = await reader.recentThreads(
        channel,
        DateTime.now().subtract(activeThreadWindow),
        limit: activeThreadLimit,
      );
    } catch (e) {
      logDebug('[Threads] archive active list failed: $e');
    }
    if (!isMounted()) return;
    _archiveActiveLoading = false;
    _archiveActiveReady = true;
    _archiveActive = threads;
    _archiveActiveChannel = channel;
    threadsListVersion.value++;
    if (_archiveActiveDirty) {
      _archiveActiveDirty = false;
      _loadActiveThreads();
    }
  }

  /// Loads the open thread's archived replies, then rebuilds the Thread tab
  /// from live, saved and archive rows. Cached per root.
  Future<void> _loadArchivedThread({bool force = false}) async {
    final root = panelManager.openThreadRoot ?? _lastThreadRoot;
    final channel = root?.channel;
    final rootId = root?.replyThreadRootId ?? root?.messageId;
    final reader = archiveReader;
    if (reader == null || channel == null || rootId == null) return;
    final key = '$channel:$rootId';
    if (!force && _archivedThreadKey == key) {
      _showThreadRows(key);
      return;
    }
    final token = ++_archivedThreadLoad;
    var rows = const <TwitchMessage>[];
    try {
      rows = await reader.threadRows(channel, rootId);
    } catch (e) {
      logDebug('[Threads] archive thread failed: $e');
    }
    if (token != _archivedThreadLoad || !isMounted()) return;
    _archivedThreadKey = key;
    _archivedThreadRows = rows;
    _adoptArchivedRoot(rows);
    _showThreadRows(key);
  }

  /// Opens on a header from the archive when the open row is a reply and no
  /// buffer or saved row holds the real root.
  void _adoptArchivedRoot(List<TwitchMessage> rows) {
    final open = panelManager.openThreadRoot;
    final channel = open?.channel;
    final rootId = open?.replyThreadRootId ?? open?.messageId;
    if (open == null || channel == null || rootId == null) return;
    if (open.messageId == rootId) return;
    if (rows.any((m) => m.messageId == rootId)) return;
    if (resolveThreadRootMessage(channel, rootId) != null) return;
    final header = _archivedRoot(channel, rootId, rows);
    if (header == null) return;
    panelManager.openThreadRoot = header;
    _lastThreadRoot = header;
  }

  /// The panel's ChatView keeps the list it was built with, so new rows go
  /// into that list instead of a replacement, which the view would never see.
  void _setThreadRows(List<TwitchMessage> rows) {
    panelManager.threadMessages
      ..clear()
      ..addAll(rows);
  }

  void _showThreadRows(String key) {
    final root = panelManager.openThreadRoot;
    if (root == null) return;
    final openKey =
        '${root.channel}:${root.replyThreadRootId ?? root.messageId}';
    if (openKey != key) return;
    _setThreadRows(computeThreadMessages());
    threadMsgCount.value++;
    threadsListVersion.value++;
  }

  /// A root header derived from a thread's first archived reply, for a thread
  /// whose root row left the buffer and the store.
  TwitchMessage? _archivedRoot(
    String channel,
    String rootId,
    List<TwitchMessage> rows,
  ) {
    if (rows.isEmpty) return null;
    final first = rows.first;
    return TwitchMessage(
      login: first.replyToUser ?? '',
      displayName: first.replyToUser ?? '',
      text: first.replyToText ?? '',
      messageId: rootId,
      channel: channel,
      timestamp: first.timestamp.subtract(const Duration(milliseconds: 1)),
    );
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
      _setThreadRows(computeThreadMessages());
      threadMsgCount.value++;
      // Watching the Thread tab marks it seen so the Active row does not
      // flip back to unread while you stare at it.
      if (effectiveThreadsTab == 0) {
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
          changedChannel != selectedChannel() &&
          changedChannel != panelManager.threadChannel) {
        return;
      }
      if (effectiveThreadsTab == 1) {
        _loadActiveThreads();
      } else {
        threadsListVersion.value++;
      }
    }
  }

  String? threadRootIdOf(TwitchMessage msg) =>
      msg.replyThreadRootId ?? msg.messageId;

  // Resolves the actual root message for a thread key, so bookmarks snapshot
  // the root's author/text instead of whichever reply got long-pressed.
  TwitchMessage? resolveThreadRootMessage(String channel, String rootId) {
    final indexed = chat.channelFor(channel)?.threads.threadFor(rootId);
    if (indexed != null) {
      for (final m in indexed) {
        if (m.messageId == rootId) return m;
      }
    }
    final buffered = chat.channelFor(channel)?.messages.items;
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
    if (isMounted()) {
      markDirty();
      showNotice(
        saved
            ? (willEvict ? strings().threadSavedEvicted : strings().threadSaved)
            : strings().threadUnsaved,
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

    final live = chat.channelFor(channel)?.threads.threadFor(rootId);
    if (live != null) {
      for (final m in live) {
        add(m);
      }
    } else {
      final buffered = chat.channelFor(channel)?.messages.items;
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
    if (_archivedThreadKey == '$channel:$rootId') {
      for (final m in _archivedThreadRows) {
        add(m);
      }
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  Future<void> openActiveThread(ThreadSummary summary, String channel) async {
    final msgs = chat.channelFor(channel)?.threads.threadFor(summary.rootId);
    var target = summary.root;
    target ??= msgs?.firstOrNull;
    target ??= resolveThreadRootMessage(channel, summary.rootId);
    if (target == null) {
      // A root no buffer holds anymore: its replies still carry its author
      // and text.
      final reader = archiveReader;
      if (reader == null) {
        showNotice(strings().threadUnavailable);
        return;
      }
      try {
        final rows = await reader.threadRows(channel, summary.rootId);
        if (!isMounted()) return;
        target = _archivedRoot(channel, summary.rootId, rows);
      } catch (e) {
        logDebug('[Threads] archive open failed: $e');
      }
      if (target == null) {
        showNotice(strings().threadUnavailable);
        return;
      }
    }
    await showThreadView(target);
  }

  void openSavedThread(SavedThread entry) {
    // Saved threads open offline: the persisted log renders even when the
    // channel is not joined, and no channel switch happens in that case.
    final joined = chat.contains(entry.channel);
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
    final root = panelManager.openThreadRoot;
    final channel = root?.channel;
    final rootId = root == null
        ? null
        : (root.replyThreadRootId ?? root.messageId);
    final live = thread_graph.computeThreadMessages(
      openThreadRoot: root,
      messagesFor: (c) => chat.channelFor(c)?.messages.items,
      threadFor: (ch, rootId) => chat.channelFor(ch)?.threads.threadFor(rootId),
    );
    // Saved threads merge the persisted full log so the view survives buffer
    // eviction and restarts. Archived replies join both, and live rows win on
    // id conflicts.
    final saved =
        channel != null &&
            rootId != null &&
            savedThreads.isSaved(channel, rootId)
        ? savedThreads.messagesFor(channel, rootId)
        : const <TwitchMessage>[];
    final archived =
        channel != null &&
            rootId != null &&
            _archivedThreadKey == '$channel:$rootId'
        ? _archivedThreadRows
        : const <TwitchMessage>[];
    return mergeThreadMessages(
      live: live,
      saved: saved,
      archived: archived,
      root: root,
    );
  }

  void onThreadsTabChanged() {
    if (threadsTab().indexIsChanging) return;
    tabDragFocus.syncFromController();
  }

  void _onThreadsFocus(int index) {
    if (index == 1) _loadActiveThreads();
    if (index == 0) unawaited(_loadArchivedThread());
    // Returning to the Thread tab marks the open thread seen so its Active
    // row clears its unread highlight.
    if (index == 0 && panelManager.openThreadRoot != null) {
      final channel = panelManager.openThreadRoot!.channel;
      final rootId =
          panelManager.openThreadRoot!.replyThreadRootId ??
          panelManager.openThreadRoot!.messageId;
      if (channel != null && rootId != null) {
        threadLastSeen['$channel:$rootId'] = DateTime.now();
        threadsListVersion.value++;
      }
    }
    // Live crossings rebuild through notifiers alone (list, composer);
    // settle keeps the full rebuild for tab-tap parity.
    if (tabDragFocus.dragFocus.value == null) markDirty();
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
      header: panelHeader(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: context.l10n.back,
          onPressed: closePanel,
        ),
        tabs: TabBar(
          controller: threadsTab(),
          // Offsets the leading button so the tabs center on the screen.
          padding: const EdgeInsets.only(right: 40),
          // Three tabs in the mentions-width island: center the strip so it
          // reads the same, and let it scroll instead of clipping labels on
          // narrow phones.
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          tabs: [
            Tab(text: context.l10n.tabThread),
            Tab(text: context.l10n.tabActive),
            Tab(text: context.l10n.tabSaved),
          ],
        ),
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: tabDragFocus.onNotification,
        child: TabBarView(
          key: ValueKey(_openCount),
          controller: threadsTab(),
          children: [
            ChatView(
              key: const ValueKey('thread_panel'),
              hides: chat.filter.hides,
              channel: panelManager.threadChannel ?? '',
              messages: panelManager.threadMessages,
              atBottomNotifier: threadAtBottom,
              messageNotifier: threadMsgCount,
              scrollController: threadPanelScrollCtrl,
              messageBuilder: messageBuilder,
              showTimestamp: showTimestamps(),
              timestampFormat: timestampFormat(),
              chatFontScale: chatFontSize() / 14.0,
              checkeredMessages: checkeredMessages(),
              highlightOpacity: highlightOpacity(),
              lineSeparator: lineSeparator(),
              sharedChatMode: sharedChatMode(),
              paintService: namePaintService(),
              onShowUserProfile: (ctx, login, userId, {displayName}) =>
                  userSheets.showUserProfile(
                    ctx,
                    login,
                    userId,
                    displayName: displayName,
                  ),
              onShowMessageMenu: (ctx, msg) =>
                  menus.showPanelMessageMenu(ctx, msg),
              onCopyMessage: copyMessage,
              showReplyIndicators: false,
              emptyText: context.l10n.noMessagesFound,
            ),
            _activeThreadsList(context),
            _savedThreadsList(context),
          ],
        ),
      ),
    );
  }

  Widget _activeThreadsList(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: threadsListVersion,
      builder: (context, _, _) {
        final channel = selectedChannel() ?? panelManager.threadChannel;
        if (channel == null) {
          return Center(child: Text(context.l10n.joinChannelForThreads));
        }
        final liveThreads =
            chat.channelFor(channel)?.threads.activeThreads() ??
            const <ThreadSummary>[];
        final archived = _archiveActiveReady && _archiveActiveChannel == channel
            ? _archiveActive
            : null;
        if (archived == null && _archiveActiveLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final threads = mergeActiveThreads(
          liveThreads,
          archived ?? const [],
          DateTime.now(),
        );
        if (threads.isEmpty) {
          return Center(child: Text(context.l10n.noActiveThreads));
        }
        final theme = Theme.of(context);
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: threads.length + 1,
          itemBuilder: (context, i) {
            if (i == threads.length) return const IslandSpacer();
            final summary = threads[i];
            final unread = isThreadUnread(channel, summary);
            // Orphan threads have no root yet; show the newest reply by
            // timestamp so the row still identifies the conversation.
            final live = chat
                .channelFor(channel)
                ?.threads
                .threadFor(summary.rootId);
            final display =
                summary.root ??
                (live == null ? null : newestThreadMessage(live));
            final author = display != null
                ? (display.displayName.isNotEmpty
                      ? display.displayName
                      : display.login)
                : summary.previewAuthor.isNotEmpty
                ? summary.previewAuthor
                : context.l10n.thread;
            final preview = display != null
                ? display.text
                : summary.previewText;
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
                '${context.l10n.replyCount(summary.replyCount)}'
                ' · ${formatTimestamp(summary.lastActivity, timestampFormat())}',
              ),
              trailing: display == null
                  ? null
                  : IconButton(
                      icon: Icon(
                        saved ? Icons.bookmark : Icons.bookmark_border,
                      ),
                      tooltip: saved
                          ? context.l10n.unsaveThread
                          : context.l10n.saveThread,
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
          return Center(child: Text(context.l10n.noSavedThreads));
        }
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: saved.length + 1,
          itemBuilder: (context, i) {
            if (i == saved.length) return const IslandSpacer();
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
                tooltip: context.l10n.unsaveThread,
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
    if (isMounted()) {
      markDirty();
      showNotice(strings().threadUnsaved);
    }
  }
}

/// Active threads: archive roots plus live roots the archive has not sealed,
/// with activity in the last 24 hours. Longest first, then newest activity.
List<ThreadSummary> mergeActiveThreads(
  List<ThreadSummary> live,
  List<ArchivedThreadRow> archived,
  DateTime now, {
  Duration window = ThreadPanels.activeThreadWindow,
  int limit = ThreadPanels.activeThreadLimit,
}) {
  final since = now.subtract(window);
  final liveById = {for (final l in live) l.rootId: l};
  final archivedIds = {for (final a in archived) a.rootId};
  final out = <ThreadSummary>[];
  for (final a in archived) {
    final held = liveById[a.rootId];
    final last = held == null || held.lastActivity.isBefore(a.lastActivity)
        ? a.lastActivity
        : held.lastActivity;
    if (last.isBefore(since)) continue;
    out.add(
      ThreadSummary(
        rootId: a.rootId,
        root: held?.root,
        lastActivity: last,
        // The archive is exact for sealed replies; a live count can hold
        // rows it has not sealed yet.
        replyCount: held == null || a.replyCount >= held.replyCount
            ? a.replyCount
            : held.replyCount,
        previewAuthor: held?.previewAuthor.isNotEmpty ?? false
            ? held!.previewAuthor
            : a.author,
        previewText: held?.previewText.isNotEmpty ?? false
            ? held!.previewText
            : a.preview,
      ),
    );
  }
  for (final l in live) {
    if (archivedIds.contains(l.rootId) || l.lastActivity.isBefore(since)) {
      continue;
    }
    out.add(l);
  }
  out.sort((a, b) {
    final byReplies = b.replyCount.compareTo(a.replyCount);
    if (byReplies != 0) return byReplies;
    final byTime = b.lastActivity.compareTo(a.lastActivity);
    return byTime != 0 ? byTime : a.rootId.compareTo(b.rootId);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// One thread's rows: [live] and [saved] newest first, plus [archived]
/// replies, deduped by id. The [root] row joins when the archive holds
/// replies but no row carries the root id.
List<TwitchMessage> mergeThreadMessages({
  required List<TwitchMessage> live,
  required List<TwitchMessage> saved,
  required List<TwitchMessage> archived,
  required TwitchMessage? root,
}) {
  final seen = <String>{};
  final out = <TwitchMessage>[];
  void add(TwitchMessage m) {
    final id = m.messageId;
    if (id != null && !seen.add(id)) return;
    out.add(m);
  }

  for (final m in live) {
    add(m);
  }
  for (final m in saved) {
    add(m);
  }
  for (final m in archived) {
    add(m);
  }
  if (root != null && archived.isNotEmpty) add(root);
  out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return out;
}
