import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat.dart';
import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';

// Which fields the query matches against.
enum ChatSearchScope { all, messages, chatters }

// Hide drops non-matches; dim fades them in place.
enum ChatSearchDisplay { hide, dim }

// Stream filters live; pause freezes the buffer snapshot.
enum ChatSearchLive { stream, pause }

// View-only filter for one channel. Kernel state is untouched.
class ChatSearchFilter {
  final String query;
  final ChatSearchScope scope;
  final ChatSearchDisplay display;
  final ChatSearchLive live;

  const ChatSearchFilter({
    this.query = '',
    this.scope = ChatSearchScope.all,
    this.display = ChatSearchDisplay.hide,
    this.live = ChatSearchLive.stream,
  });

  bool get isActive => query.trim().isNotEmpty;

  ChatSearchFilter copyWith({
    String? query,
    ChatSearchScope? scope,
    ChatSearchDisplay? display,
    ChatSearchLive? live,
  }) {
    return ChatSearchFilter(
      query: query ?? this.query,
      scope: scope ?? this.scope,
      display: display ?? this.display,
      live: live ?? this.live,
    );
  }
}

// Case-insensitive substring match. System rows never match.
bool searchMatches(TwitchMessage msg, ChatSearchFilter filter) =>
    searchMatchesLower(msg, filter.query.trim().toLowerCase(), filter.scope);

// Hoisted-query variant for per-tile loops; avoids re-lowercasing per row.
bool searchMatchesLower(
  TwitchMessage msg,
  String qLower,
  ChatSearchScope scope,
) {
  if (qLower.isEmpty) return true;
  if (msg.isSystem) return false;
  final inText = msg.text.toLowerCase().contains(qLower);
  final inUser =
      msg.login.toLowerCase().contains(qLower) ||
      msg.displayName.toLowerCase().contains(qLower);
  return switch (scope) {
    ChatSearchScope.messages => inText,
    ChatSearchScope.chatters => inUser,
    ChatSearchScope.all => inText || inUser,
  };
}

// Shell-owned state the search filter reads but does not own.
abstract class SearchPanelsHost extends ShellState {
  bool isMounted();
  void markDirty();
  bool get showInput;
  void setShowInput(bool value);
  bool get emoteSheetOpen;
  Future<void> closeEmoteSheet();
  void clearComposerSuggestions();
  FocusNode get composerFocusNode;
}

// Per-channel view-only search. Kernel lists are never touched;
// ChatView gets a filtered copy and the tile cache stays valid.
class SearchPanels {
  SearchPanels({required this.chat, required this.host});

  final Chat chat;
  final SearchPanelsHost host;

  // Per-channel ticks so keystrokes rebuild one page, not every tab.
  // Notifiers outlive forget (same deferred-disposal rule as the at-bottom
  // notifiers); all die in dispose.
  final _versions = <String, ValueNotifier<int>>{};
  bool open = false;
  final _filters = <String, ChatSearchFilter>{};
  final _frozen = <String, List<TwitchMessage>>{};
  final field = TextEditingController();

  // Shared with the composer: mode swaps keep focus, keyboard stays up.
  FocusNode get focusNode => host.composerFocusNode;

  void dispose() {
    for (final v in _versions.values) {
      v.dispose();
    }
    field.dispose();
  }

  ValueNotifier<int> channelVersion(String channel) =>
      _versions.putIfAbsent(channel, () => ValueNotifier(0));

  void _bump(String channel) => channelVersion(channel).value++;

  ChatSearchFilter stateFor(String channel) =>
      _filters[channel] ?? const ChatSearchFilter();
  // Filtered rows for ChatView. Dim mode returns the full base list;
  // non-matches fade per tile via dimPredicate.
  List<TwitchMessage> visibleMessages(String channel) {
    final filter = stateFor(channel);
    if (!open || !filter.isActive) {
      return chat.channelFor(channel)?.messages.items ?? const [];
    }
    final q = filter.query.trim().toLowerCase();
    var base = filter.live == ChatSearchLive.pause
        ? (_frozen[channel] ?? const <TwitchMessage>[])
        : (chat.channelFor(channel)?.messages.items ?? const <TwitchMessage>[]);
    if (filter.live == ChatSearchLive.pause) {
      // Drops rows evicted by truncation/deletes while frozen.
      final liveIds = {
        for (final m in chat.channelFor(channel)?.messages.items ?? const [])
          if (m.messageId != null) m.messageId!,
      };
      base = base
          .where((m) => m.messageId == null || liveIds.contains(m.messageId))
          .toList();
    }
    if (filter.display == ChatSearchDisplay.dim) return base;
    return base.where((m) => searchMatchesLower(m, q, filter.scope)).toList();
  }

  // Null unless dimming is active; true means fade this row.
  bool Function(TwitchMessage)? dimPredicate(String channel) {
    final filter = stateFor(channel);
    if (!open || !filter.isActive || filter.display != ChatSearchDisplay.dim) {
      return null;
    }
    final q = filter.query.trim().toLowerCase();
    return (m) => !searchMatchesLower(m, q, filter.scope);
  }

  // Empty-state copy: hide mode with a query shows matches or nothing.
  String? emptyText(String channel) {
    final filter = stateFor(channel);
    if (open && filter.isActive && filter.display == ChatSearchDisplay.hide) {
      return 'No matches';
    }
    return null;
  }

  void toggleSearch() {
    if (open) {
      closeSearch();
    } else {
      if (host.selectedChannel == null) return;
      if (!host.showInput) {
        host.setShowInput(true);
        _restoredInput = true;
      }
      if (host.emoteSheetOpen) unawaited(host.closeEmoteSheet());
      host.clearComposerSuggestions();
      open = true;
      syncFieldTo(host.selectedChannel);
      host.markDirty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (open && host.isMounted()) focusNode.requestFocus();
      });
    }
  }

  // Restores the input visibility from before, so search never flips prefs.
  bool _restoredInput = false;

  // Close clears every channel so a reopen never resurrects stale queries.
  // focusComposer skips the unfocus: shared focus survives the swap.
  void closeSearch({bool focusComposer = false}) {
    if (!open) return;
    open = false;
    if (_restoredInput) {
      _restoredInput = false;
      host.setShowInput(false);
    }
    _filters.clear();
    _frozen.clear();
    field.clear();
    if (!focusComposer) focusNode.unfocus();
    host.markDirty();
  }

  void setQuery(String channel, String query) {
    if (stateFor(channel).query == query) return;
    _filters[channel] = stateFor(channel).copyWith(query: query);
    _bump(channel);
  }

  void setScope(String channel, ChatSearchScope scope) {
    _filters[channel] = stateFor(channel).copyWith(scope: scope);
    _bump(channel);
  }

  void setDisplay(String channel, ChatSearchDisplay display) {
    _filters[channel] = stateFor(channel).copyWith(display: display);
    _bump(channel);
  }

  void setLive(String channel, ChatSearchLive live) {
    _filters[channel] = stateFor(channel).copyWith(live: live);
    if (live == ChatSearchLive.pause) {
      _frozen[channel] = List.of(
        chat.channelFor(channel)?.messages.items ?? const [],
      );
    } else {
      _frozen.remove(channel);
    }
    _bump(channel);
  }

  // Drop per-channel state on leave; session-only by design.
  void forget(String channel) {
    _filters.remove(channel);
    _frozen.remove(channel);
    // Deferred like the at-bottom notifiers: listeners unmount this frame.
    final v = _versions.remove(channel);
    if (v != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => v.dispose());
    }
    // Leaving the last channel strands the bar, so drop it quietly.
    if (chat.names.isEmpty && open) {
      open = false;
      field.clear();
      focusNode.unfocus();
    }
  }

  // Keep the field showing the newly selected channel's query.
  void syncFieldTo(String? channel) {
    final query = channel == null ? '' : stateFor(channel).query;
    if (field.text == query) return;
    field.text = query;
    field.selection = TextSelection.collapsed(offset: query.length);
  }

  void _select(String channel, String value) {
    switch (value) {
      case 'scope_all':
        setScope(channel, ChatSearchScope.all);
      case 'scope_messages':
        setScope(channel, ChatSearchScope.messages);
      case 'scope_chatters':
        setScope(channel, ChatSearchScope.chatters);
      case 'display_hide':
        setDisplay(channel, ChatSearchDisplay.hide);
      case 'display_dim':
        setDisplay(channel, ChatSearchDisplay.dim);
      case 'live_stream':
        setLive(channel, ChatSearchLive.stream);
      case 'live_pause':
        setLive(channel, ChatSearchLive.pause);
    }
  }

  Color _slotAccent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return focusNode.hasFocus ? scheme.primary : scheme.onSurfaceVariant;
  }

  // 48px prefix slot for the morphed input: closes search.
  Widget closeButton() {
    return Builder(
      builder: (context) => SizedBox(
        width: 48,
        height: 48,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => closeSearch(focusComposer: true),
            child: ListenableBuilder(
              listenable: focusNode,
              builder: (_, _) => Icon(Icons.close, color: _slotAccent(context)),
            ),
          ),
        ),
      ),
    );
  }

  // Owned menu metrics for the dense rows below. _menuH must match
  // their sum (header + 7 rows + 2 dividers + M3 menuPadding vertical)
  // or the open-up offset below lands in the wrong place.
  static const _menuHeaderH = 28.0;
  static const _menuRowH = 36.0;
  static const _menuDivH = 8.0;
  static const _menuH = _menuHeaderH + 7 * _menuRowH + 2 * _menuDivH + 16.0;

  // 48px suffix slot for the morphed input: the filter menu.
  // requestFocus false keeps the keyboard up: the menu route never
  // steals focus from the search field.
  Widget filterButton() {
    return Builder(
      builder: (context) => PopupMenuButton<String>(
        tooltip: 'Search filters',
        padding: EdgeInsets.zero,
        requestFocus: false,
        // Top-anchored at button top minus menu height: opens upward,
        // above the keyboard. Top-down growth, like every popup.
        position: PopupMenuPosition.over,
        offset: const Offset(0, -_menuH),
        popUpAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 175),
        ),
        onSelected: (value) {
          final channel = host.selectedChannel;
          if (channel != null) _select(channel, value);
        },
        itemBuilder: (_) {
          final filter = stateFor(host.selectedChannel ?? '');
          return [
            _menuHeader('Filter'),
            _menuRow(
              value: 'scope_all',
              label: 'All',
              checked: filter.scope == ChatSearchScope.all,
            ),
            _menuRow(
              value: 'scope_messages',
              label: 'Messages',
              checked: filter.scope == ChatSearchScope.messages,
            ),
            _menuRow(
              value: 'scope_chatters',
              label: 'Users',
              checked: filter.scope == ChatSearchScope.chatters,
            ),
            const PopupMenuDivider(height: _menuDivH),
            _menuRow(
              value: 'display_hide',
              label: 'Hide',
              checked: filter.display == ChatSearchDisplay.hide,
            ),
            _menuRow(
              value: 'display_dim',
              label: 'Dim',
              checked: filter.display == ChatSearchDisplay.dim,
            ),
            const PopupMenuDivider(height: _menuDivH),
            _menuRow(
              value: 'live_stream',
              label: 'Stream',
              checked: filter.live == ChatSearchLive.stream,
            ),
            _menuRow(
              value: 'live_pause',
              label: 'Pause',
              checked: filter.live == ChatSearchLive.pause,
            ),
          ];
        },
        child: SizedBox(
          width: 48,
          height: 48,
          child: ListenableBuilder(
            listenable: focusNode,
            builder: (_, _) => Icon(Icons.tune, color: _slotAccent(context)),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuHeader(String label) {
    return PopupMenuItem<String>(
      enabled: false,
      height: _menuHeaderH,
      child: SizedBox(
        height: _menuHeaderH,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuRow({
    required String value,
    required String label,
    required bool checked,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: _menuRowH,
      child: SizedBox(
        height: _menuRowH,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: checked ? const Icon(Icons.done, size: 18) : null,
            ),
            Text(label),
          ],
        ),
      ),
    );
  }
}
