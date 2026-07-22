import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/twitch_irc_read.dart';
import '../services/recent_messages.dart';
import '../services/seven_tv_event_client.dart';
import '../services/command_handler.dart';
import '../services/chat_connection_manager.dart';
import '../services/emote_manager.dart';
import '../services/twitch_badge_service.dart';
import '../services/emote_providers/twitch_emotes.dart';
import '../widgets/settings.dart';
import '../widgets/emote_text.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/tabbed_layout.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../services/user_store.dart';
import '../services/suggestion.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/user_profile_sheet.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/message_input.dart';
import '../widgets/thread_panel.dart';
import '../widgets/mentions_panel.dart';
import '../widgets/emote_menu_panel.dart';
import '../services/foreground_task.dart';

enum OverlayPanel { closed, thread, mentions, emotes }

class HomeScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final SevenTvEventClient? sevenTvEventClient;
  final String? initialCurrentUserLogin;

  const HomeScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.sevenTvEventClient,
    this.initialCurrentUserLogin,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _mentionsChannel = '@mentions';

  late final _eventSub = widget.eventSubService ?? EventSubService();
  late final _irc = widget.ircService ?? IrcService();
  late final _ircRead = widget.ircReadService ?? IrcReadService();
  late final _recentMessages =
      widget.recentMessagesService ?? RecentMessagesService();
  late final _sevenTvClient = widget.sevenTvEventClient ?? SevenTvEventClient();
  late final _chatConn = ChatConnectionManager(
    eventSub: _eventSub,
    irc: _irc,
    ircRead: _ircRead,
    sevenTvClient: _sevenTvClient,
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    userStore: _userStore,
    twitchAuth: widget.twitchAuth,
    channelMessages: _channelMessages,
    messageKeys: _messageKeys,
    chatStatus: _chatStatus,
    channelsWithUnread: _channelsWithUnread,
    channelsWithUnreadMentions: _channelsWithUnreadMentions,
    unreadMentionsPerChannel: _unreadMentionsPerChannel,
    channels: _channels,
    historyLoaded: _historyLoaded,
    channelsEmotesResolved: _channelsEmotesResolved,
    channelUserIds: _channelUserIds,
    pendingLocals: _pendingLocals,
    lastTypedText: _lastTypedText,
    lastSentWireText: _lastSentWireText,
    ownMessageIds: _ownMessageIds,
    chatVersion: _chatVersion,
    mentionsChannel: _mentionsChannel,
    onRebuild: () {
      if (mounted) setState(() {});
    },
    onSystemMessage: _addSystemMessage,
    loadUserTwitchEmotes: _loadUserTwitchEmotes,
    getMaxMessagesPerChannel: () => _maxMessagesPerChannel,
    getSelectedChannel: () => _selectedChannel,
    getUnreadMentions: () => _unreadMentions,
    setUnreadMentions: (v) => _unreadMentions = v,
    getCurrentUserLogin: () => _currentUserLogin,
    setCurrentUserLogin: (v) {
      _currentUserLogin = v;
      _scanHistoryForMentions();
    },
    getCurrentUserId: () => _currentUserId,
    setCurrentUserId: (v) => _currentUserId = v,
    getCurrentUserColor: () => _currentUserColor,
    setCurrentUserColor: (v) => _currentUserColor = v,
    onCommand: _handleCommand,
    getReplyToMsg: () => _replyToMsg,
    setReplyToMsg: (v) => _replyToMsg = v,
    onRequestFocus: () => _focusNode.requestFocus(),
    onShowSnackBar: (msg) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    },
  );
  late final _commandHandler = CommandHandler(
    irc: _irc,
    getChannelUserIds: () => _channelUserIds,
    getCurrentUserId: () => _currentUserId,
    getCurrentUserLogin: () => _currentUserLogin,
    addSystemMessage: _addSystemMessage,
  );
  final _messageController = TextEditingController();
  final _focusNode = FocusNode();

  final _emoteManager = EmoteManager();
  final _badgeService = TwitchBadgeService();
  final _userStore = UserStore();
  final _channels = <String>[];
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _chatVersion = ValueNotifier(0);
  String? _selectedChannel;
  final _channelMessages = <String, List<TwitchMessage>>{};
  final _scrollControllers = <String, ScrollController>{};
  final _isAtBottom = <String, bool>{};
  final _frozenSnapshot = <String, List<TwitchMessage>>{};
  final _historyLoaded = <String>{};
  final _messageKeys = <String, GlobalKey>{};
  final _chatStatus = <String, String>{};
  final _channelUserIds = <String, String>{};
  final _channelsEmotesResolved = <String>{};
  int _unreadMentions = 0;
  final _channelsWithUnread = <String>{};
  final _channelsWithUnreadMentions = <String>{};
  final _unreadMentionsPerChannel = <String, int>{};

  TwitchMessage? _replyToMsg;
  TwitchMessage? _openThreadRoot;
  OverlayPanel _activePanel = OverlayPanel.closed;
  int _maxMessagesPerChannel = 200;

  final _suggestionsNotifier = ValueNotifier<List<Suggestion>>([]);

  final _threadSheetRatio = ValueNotifier(0.0);
  final _mentionsSheetRatio = ValueNotifier(0.0);
  late final DraggableScrollableController _emoteSheetCtrl;
  final _threadPanelScrollCtrl = ScrollController();
  final _mentionsPanelScrollCtrl = ScrollController();
  double _panelDragStartRatio = 0.0;
  double _panelDragStartY = 0.0;
  static const _sheetAnimDuration = Duration(milliseconds: 250);
  static const _sheetCloseDuration = Duration(milliseconds: 180);
  static const _emoteMaxFraction = 0.6;
  static const _fullHeightFraction = 1.0;
  double? _emoteSheetBoxHeight;
  final _threadPanelData = ValueNotifier<ThreadPanelData?>(null);
  final _mentionsPanelData = ValueNotifier<List<TwitchMessage>?>(null);

  final _ownMessageIds = <String>{};
  final _pendingLocals = <String, PendingLocal>{};

  String? _currentUserLogin;
  bool _mentionScanDone = false;
  String? _currentUserColor;
  String? _currentUserId;
  String? _lastSentText;
  final Map<String, String> _lastTypedText = {};
  final Map<String, String> _lastSentWireText = {};

  void _onSheetSizeChanged(
    OverlayPanel panel,
    DraggableScrollableController ctrl,
  ) {
    // When the user drags a sheet down to size 0, close the panel.
    if (_activePanel == panel && ctrl.isAttached && ctrl.size <= 0.001) {
      setState(() {
        _activePanel = OverlayPanel.closed;
        if (panel == OverlayPanel.thread) {
          _openThreadRoot = null;
          _threadPanelData.value = null;
        } else if (panel == OverlayPanel.mentions) {
          _mentionsPanelData.value = null;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _currentUserLogin = widget.initialCurrentUserLogin;
    _emoteSheetCtrl = DraggableScrollableController();
    _emoteSheetCtrl.addListener(
      () => _onSheetSizeChanged(OverlayPanel.emotes, _emoteSheetCtrl),
    );
    _emoteSheetCtrl.addListener(
      () => _onSheetSizeChanged(OverlayPanel.emotes, _emoteSheetCtrl),
    );
    _chatVersion.addListener(_onPanelDataChanged);
    _loadMaxMessages();
    _loadChannels();
    _chatConn.connect();
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _emoteManager.preloadGlobalEmotes();
    _emoteManager.addListener(_onEmotesChanged);
    _badgeService.fetchGlobalBadges(widget.twitchAuth);
    widget.twitchAuth.addListener(_onAuthChanged);
    _focusNode.addListener(_onInputFocusChanged);
    _messageController.addListener(_onInputChanged);
    WidgetsBinding.instance.addObserver(this);
    _initForegroundService();
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused) {
      startForegroundService(List.of(_channels));
    } else if (state == AppLifecycleState.resumed) {
      stopForegroundService();
    }
  }

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(_channels));
  }

  void _reorderChannels(List<String> reordered) {
    _channels
      ..clear()
      ..addAll(reordered);
    _channelNotifier.value = List.of(_channels);
    _saveChannels();
  }

  Future<void> _loadChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('channels');
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (_channels.contains(name)) continue;
      _channels.add(name);
      _channelMessages.putIfAbsent(name, () => []);
      _isAtBottom[name] = true;
    }
    _channelNotifier.value = List.of(_channels);
    _selectedChannel = _channels.first;
    if (mounted) setState(() {});
    for (final name in saved) {
      _subscribeChannel(name);
      _recentMessages
          .fetchRecent(name)
          .then((history) {
            if (!mounted) return;
            _historyLoaded.add(name);
            setState(() {
              if (history.isEmpty) {
                _addSystemMessage(name, 'No chat history available');
              } else {
                final existing = _channelMessages[name]!;
                final existingIds = existing.map((m) => m.messageId).toSet();
                for (final msg in history) {
                  final isNew =
                      msg.messageId == null ||
                      !existingIds.contains(msg.messageId);
                  if (isNew) {
                    existing.insert(0, msg);
                  }
                  if (msg.messageId != null) {
                    _messageKeys.putIfAbsent(
                      '$name:${msg.messageId}',
                      () => GlobalKey(),
                    );
                  }
                  final login = _currentUserLogin?.toLowerCase();
                  if (login != null &&
                      !msg.isSystem &&
                      !msg.isHighlighted &&
                      msg.login.toLowerCase() != login) {
                    final isReplyToMe =
                        msg.replyToUser != null &&
                        msg.replyToUser!.toLowerCase() == login;
                    if (isMention(msg.text, login) || isReplyToMe) {
                      msg.isHighlighted = true;
                      _channelMessages.putIfAbsent(_mentionsChannel, () => []);
                      final mentionList = _channelMessages[_mentionsChannel]!;
                      final existingMentionIds = mentionList
                          .map((m) => m.messageId)
                          .toSet();
                      if (msg.messageId == null ||
                          !existingMentionIds.contains(msg.messageId)) {
                        mentionList.insert(0, msg);
                      }
                    }
                  }
                }
                _truncateChannelMessages(name);
                _chatVersion.value++;
              }
            });
            _maybeAddConnected(name);
          })
          .catchError((e) {
            if (!mounted) return;
            _historyLoaded.add(name);
            _addSystemMessage(name, 'Failed to load chat history ($e)');
            _maybeAddConnected(name);
          });
    }
  }

  void _onInputFocusChanged() {
    if (_activePanel == OverlayPanel.emotes) {
      _closePanel();
    }
  }

  void _onInputChanged() {
    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final word = getCurrentWord(text, cursor);
    if (word.text.length < 2) {
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
      return;
    }
    final channel = _selectedChannel;
    if (channel == null) return;
    final channelEmotes = _emoteManager.byCode(channel);
    final emotes = channelEmotes?.suggestions ?? [];
    final users = _userStore.usersForChannel(channel);
    final filtered = filterSuggestions(
      word: word.text,
      emotes: emotes,
      users: users,
    );
    _suggestionsNotifier.value = filtered;
  }

  void _onSuggestionSelected(Suggestion suggestion) {
    final replacement = switch (suggestion) {
      UserSuggestion() => suggestion.displayName,
      EmoteSuggestion() => suggestion.emote.code,
    };
    replaceCurrentWord(_messageController, replacement);
    if (suggestion is EmoteSuggestion) {
      _emoteManager.markEmoteUsed(suggestion.emote);
    }
    _suggestionsNotifier.value = [];
    _focusNode.requestFocus();
  }

  void _onEmotesChanged() {
    for (final msgs in _channelMessages.values) {
      for (final msg in msgs) {
        msg.cachedSpans = null;
      }
    }
    _chatVersion.value++;
  }

  void _onPanelDataChanged() {
    if (_activePanel == OverlayPanel.thread && _openThreadRoot != null) {
      final channel = _openThreadRoot!.channel!;
      _threadPanelData.value = ThreadPanelData(
        root: _openThreadRoot!,
        messages: _computeThreadMessages(),
        channel: channel,
      );
    } else if (_activePanel == OverlayPanel.mentions) {
      _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
    }
  }

  void _onAuthChanged() {
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _refreshEmotesAfterAuth();
  }

  Future<void> _refreshEmotesAfterAuth() async {
    try {
      for (final channel in _channels) {
        final userId = await TwitchApi.getUserId(widget.twitchAuth, channel);
        if (userId != null) {
          _channelUserIds[channel] = userId;
        }
      }
      _emoteManager.evictGlobal();
      _emoteManager.preloadGlobalEmotes();
      _badgeService.dispose();
      _badgeService.fetchGlobalBadges(widget.twitchAuth);
      for (final channel in _channels) {
        _emoteManager.evictChannel(channel);
        final userId = _channelUserIds[channel];
        if (userId != null) {
          _badgeService.fetchChannelBadges(widget.twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        _channels.map(
          (c) => _emoteManager.resolveEmotes(c, _channelUserIds[c]),
        ),
      );
      _chatConn.userTwitchEmotesLoaded = false;
      unawaited(_loadUserTwitchEmotes());
    } catch (e) {
      debugPrint('_refreshEmotesAfterAuth failed: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadUserTwitchEmotes() async {
    final auth = widget.twitchAuth;
    final userId = _currentUserId;
    if (!auth.isConfigured || userId == null) return;
    final byOwner = await TwitchEmoteProvider.fetchUserEmotes(
      userId: userId,
      accessToken: auth.accessToken,
    );
    if (byOwner.isEmpty) return;
    final userIdToChannel = <String, String>{};
    for (final entry in _channelUserIds.entries) {
      userIdToChannel[entry.value] = entry.key;
    }
    final unknownIds = <String>[];
    for (final ownerId in byOwner.keys) {
      if (ownerId.isEmpty) continue;
      if (!userIdToChannel.containsKey(ownerId)) {
        unknownIds.add(ownerId);
      }
    }
    if (unknownIds.isNotEmpty) {
      final resolved = await TwitchApi.getUserLoginsByIds(auth, unknownIds);
      userIdToChannel.addAll(resolved);
    }
    final perChannel = <String, List<GenericEmote>>{};
    for (final entry in byOwner.entries) {
      if (entry.key.isEmpty) continue;
      final channel = userIdToChannel[entry.key];
      if (channel == null) continue;
      perChannel[channel] = entry.value
          .map(
            (e) => GenericEmote(
              id: e.id,
              code: e.code,
              type: e.type,
              url: e.url,
              isAnimated: e.isAnimated,
              scope: e.scope,
              tier: e.tier,
              emoteType: e.emoteType,
              ownerChannel: channel,
            ),
          )
          .toList();
    }
    if (perChannel.isNotEmpty) {
      await _emoteManager.storeUserTwitchEmotes(perChannel);
    }
  }

  void _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _maxMessagesPerChannel = prefs.getInt('max_messages_per_channel') ?? 200;
    });
  }

  @override
  void dispose() {
    _chatConn.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _eventSub.dispose();
    _irc.dispose();
    _ircRead.dispose();
    _sevenTvClient.dispose();
    _emoteManager.removeListener(_onEmotesChanged);
    widget.twitchAuth.removeListener(_onAuthChanged);
    _messageController.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _focusNode.dispose();
    _chatVersion.removeListener(_onPanelDataChanged);
    _threadSheetRatio.dispose();
    _mentionsSheetRatio.dispose();
    _emoteSheetCtrl.dispose();
    _threadPanelScrollCtrl.dispose();
    _mentionsPanelScrollCtrl.dispose();
    _threadPanelData.dispose();
    _mentionsPanelData.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    _chatVersion.dispose();
    super.dispose();
  }

  void _addSystemMessage(String channel, String text) {
    _channelMessages.putIfAbsent(channel, () => []);
    _channelMessages[channel]!.insert(
      0,
      TwitchMessage(login: '', text: text, isSystem: true, channel: channel),
    );
    _truncateChannelMessages(channel);
    _chatVersion.value++;
  }

  void _showMessageMenu(TwitchMessage msg) {
    final threadRoot = _findThreadRoot(msg);
    final hasThread = threadRoot != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply to message'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _replyToMsg = msg;
                });
                _focusNode.requestFocus();
              },
            ),
            if (hasThread)
              ListTile(
                leading: const Icon(Icons.forum),
                title: const Text('View thread'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showThreadView(threadRoot);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More...'),
              onTap: () {
                Navigator.pop(ctx);
                _showMoreMenu(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showThreadMessageMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More...'),
              onTap: () {
                Navigator.pop(ctx);
                _showMoreMenu(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('Copy full message'),
              onTap: () {
                final ts =
                    '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';
                Clipboard.setData(
                  ClipboardData(
                    text: '$ts ${msg.formattedUsername}: ${msg.text}',
                  ),
                );
                Navigator.pop(ctx);
              },
            ),
            if (msg.messageId != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message ID'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.messageId!));
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _maybeAddConnected(String channel) {
    _chatConn.maybeAddConnected(channel);
  }

  Future<void> _addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _channels.contains(name)) return;

    setState(() {
      _channels.add(name);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.putIfAbsent(name, () => []);
      _isAtBottom[name] = true;
      _selectedChannel = name;
    });
    _saveChannels();
    _focusNode.requestFocus();

    final loadingMsg = TwitchMessage(
      login: '',
      text: 'Loading chat history...',
      isSystem: true,
      channel: name,
    );
    _channelMessages[name]!.insert(0, loadingMsg);

    _recentMessages
        .fetchRecent(name)
        .then((history) {
          if (!mounted) return;
          _historyLoaded.add(name);
          setState(() {
            if (history.isEmpty) {
              _addSystemMessage(name, 'No chat history available');
            } else {
              final existing = _channelMessages[name]!;
              final existingIds = existing.map((m) => m.messageId).toSet();
              for (final msg in history) {
                if (msg.messageId == null ||
                    !existingIds.contains(msg.messageId)) {
                  existing.insert(0, msg);
                }
                if (msg.messageId != null) {
                  _messageKeys.putIfAbsent(
                    '$name:${msg.messageId}',
                    () => GlobalKey(),
                  );
                }
              }
              _truncateChannelMessages(name);
              _chatVersion.value++;
            }
          });
          _maybeAddConnected(name);
        })
        .catchError((e) {
          if (!mounted) return;
          _historyLoaded.add(name);
          _addSystemMessage(name, 'Failed to load chat history ($e)');
          _maybeAddConnected(name);
        });

    final auth = widget.twitchAuth;
    if (!auth.isConfigured) {
      if (mounted) setState(() {});
      return;
    }

    debugPrint('[HomeScreen] joining channel: $name');
    await _subscribeChannel(name);

    if (mounted) setState(() {});
  }

  Future<void> _subscribeChannel(String channelName) async {
    _chatConn.subscribeChannel(channelName);
  }

  void _addChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'channel name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _addChannel(controller.text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addChannel(controller.text);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _removeChannel(String channel) {
    _irc.part(channel);
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _channelsEmotesResolved.remove(channel);
    _historyLoaded.remove(channel);
    _channelUserIds.remove(channel);
    _lastTypedText.remove(channel);
    _lastSentWireText.remove(channel);
    _chatStatus.remove(channel);
    setState(() {
      _channels.remove(channel);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.remove(channel);
      _userStore.removeChannel(channel);
      _scrollControllers.remove(channel)?.dispose();
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      _unreadMentionsPerChannel.remove(channel);
      _messageKeys.removeWhere((k, _) => k.startsWith('$channel:'));
      if (_selectedChannel == channel) {
        _selectedChannel = _channels.isNotEmpty ? _channels.last : null;
      }
    });
    _saveChannels();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _sendMessage() {
    if (_suggestionsNotifier.value.isNotEmpty) {
      _suggestionsNotifier.value = [];
    }

    final text = _messageController.text.trim();
    final channel = _selectedChannel;
    if (text.isEmpty ||
        channel == null ||
        _activePanel == OverlayPanel.mentions) {
      return;
    }

    if (!widget.twitchAuth.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect an account to chat')),
      );
      return;
    }

    _lastSentText = text;
    _messageController.clear();

    final threadRoot = _openThreadRoot;
    if (threadRoot != null) {
      final threadMsgs = _computeThreadMessages();
      final lastMsg = threadMsgs.isNotEmpty ? threadMsgs.last : null;
      _doSendMessage(text, channel, replyTo: lastMsg);
    } else {
      _doSendMessage(text, channel);
    }
  }

  void _doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    _chatConn.doSendMessage(text, channel, replyTo: replyTo);
  }

  void _onSendLongPress() {
    if (_lastSentText != null && _lastSentText!.isNotEmpty) {
      _messageController.text = _lastSentText!;
      _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: _messageController.text.length),
      );
      _focusNode.requestFocus();
    }
  }

  /// Handles slash commands by routing to the appropriate Twitch API endpoint.
  void _handleCommand(String text, String channel, TwitchAuth auth) async {
    _commandHandler.handle(text, channel, auth);
  }

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(channel, () => ScrollController());
  }

  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = _channelMessages[channel];
    if (msgs == null) return null;

    final hasReplies =
        msg.messageId != null &&
        msgs.any((m) => m.replyToParentId == msg.messageId);
    if (!hasReplies && msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null &&
        !visited.contains(current.replyToParentId)) {
      visited.add(current.replyToParentId!);
      final parent = msgs
          .where((m) => m.messageId == current.replyToParentId)
          .firstOrNull;
      if (parent == null) break;
      current = parent;
    }
    return current;
  }

  Future<void> _showThreadView(TwitchMessage rootMsg) async {
    final channel = rootMsg.channel;
    if (channel == null) return;
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    if (_selectedChannel != channel) {
      final idx = _channels.indexOf(channel);
      if (idx >= 0) _onChannelChanged(idx);
    }
    setState(() {
      _activePanel = OverlayPanel.thread;
      _openThreadRoot = rootMsg;
    });
    _threadPanelData.value = ThreadPanelData(
      root: rootMsg,
      messages: _computeThreadMessages(),
      channel: channel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _animateRatio(
          _threadSheetRatio,
          0.0,
          _fullHeightFraction,
          _sheetAnimDuration,
        );
      }
    });
  }

  Future<void> _showMentionsView() async {
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    setState(() {
      _activePanel = OverlayPanel.mentions;
      _openThreadRoot = null;
    });
    _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _animateRatio(
          _mentionsSheetRatio,
          0.0,
          _fullHeightFraction,
          _sheetAnimDuration,
        );
      }
    });
  }

  Future<void> _showEmoteMenu() async {
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    setState(() => _activePanel = OverlayPanel.emotes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _emoteSheetCtrl.isAttached) {
        _emoteSheetCtrl.animateTo(
          _emoteMaxFraction,
          duration: _sheetAnimDuration,
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onEmoteSelected(GenericEmote emote) {
    final text = _messageController.text;
    final pos = _messageController.selection.baseOffset;
    final insertPos = pos.clamp(0, text.length);
    _messageController.text =
        '${text.substring(0, insertPos)}${emote.code} ${text.substring(insertPos)}';
    _messageController.selection = TextSelection.collapsed(
      offset: insertPos + emote.code.length + 1,
    );
    _emoteManager.markEmoteUsed(emote);
  }

  Future<void> _closePanel() async {
    final panelToClose = _activePanel;
    if (panelToClose == OverlayPanel.closed) return;
    if (panelToClose == OverlayPanel.emotes) {
      if (_emoteSheetCtrl.isAttached) {
        await _emoteSheetCtrl.animateTo(
          0.0,
          duration: _sheetCloseDuration,
          curve: Curves.easeOut,
        );
      }
    } else if (panelToClose == OverlayPanel.thread) {
      await _animateRatio(
        _threadSheetRatio,
        _threadSheetRatio.value,
        0.0,
        _sheetCloseDuration,
      );
    } else if (panelToClose == OverlayPanel.mentions) {
      await _animateRatio(
        _mentionsSheetRatio,
        _mentionsSheetRatio.value,
        0.0,
        _sheetCloseDuration,
      );
    }
    if (mounted) {
      setState(() {
        _activePanel = OverlayPanel.closed;
        _openThreadRoot = null;
        _threadPanelData.value = null;
        _mentionsPanelData.value = null;
      });
    }
  }

  Future<void> _animateRatio(
    ValueNotifier<double> ratio,
    double from,
    double to,
    Duration duration,
  ) async {
    if (from == to) return;
    final controller = AnimationController(vsync: this, duration: duration);
    final animation = Tween(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOut));
    void listener() {
      ratio.value = animation.value;
    }

    animation.addListener(listener);
    await controller.forward();
    animation.removeListener(listener);
    controller.dispose();
  }

  Widget _buildPanelDragHandle({
    required ValueNotifier<double> ratio,
    required double maxSize,
    required VoidCallback onClose,
    required VoidCallback onSnap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (details) {
        _panelDragStartRatio = ratio.value;
        _panelDragStartY = details.globalPosition.dy;
      },
      onVerticalDragUpdate: (details) {
        final cumulativeDelta = details.globalPosition.dy - _panelDragStartY;
        final height =
            maxSize *
            (MediaQuery.of(context).size.height -
                MediaQuery.of(context).padding.top);
        ratio.value = (_panelDragStartRatio - cumulativeDelta / height).clamp(
          0.0,
          maxSize,
        );
      },
      onVerticalDragEnd: (_) {
        if (ratio.value < maxSize * 0.9) {
          onClose();
        } else {
          onSnap();
        }
      },
      child: Container(
        width: double.infinity,
        color: Colors.transparent,
        padding: const EdgeInsets.only(bottom: 50, top: 10), // (vertical: 20),
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheetPanel({
    required ValueNotifier<double> ratio,
    required Widget child,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.bottomCenter,
            minHeight: height,
            maxHeight: height,
            child: AnimatedBuilder(
              animation: ratio,
              builder: (context, child) {
                final closedFraction = (1.0 - ratio.value).clamp(0.0, 1.0);
                return FractionalTranslation(
                  translation: Offset(0, closedFraction),
                  child: child!,
                );
              },
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Wraps [child] so it renders at its full expanded height and translates
  /// vertically as the sheet opens/closes — true slide-up/down motion.
  ///
  /// At size = 0 the content is shifted down by its full height (invisible
  /// below the viewport). As the sheet grows to [maxSize] the content rises
  /// into view, bottom-anchored.
  ///
  /// [totalAvailH] is the pixel height of the Positioned area that the sheet
  /// occupies. Captured once per layout from a LayoutBuilder wrapping the sheet.
  ///
  /// Uses [OverflowBox] so the child always lays out at full height regardless
  /// of sheet box size, preventing Column overflow during animation. [ClipRect]
  /// clips to the sheet box boundary. [AnimatedBuilder] and [FractionalTranslation]
  /// drive the per-frame offset.
  Widget _buildSlideUpContent({
    required DraggableScrollableController controller,
    required double totalAvailH,
    required double maxSize,
    required Widget child,
  }) {
    final contentH = maxSize * totalAvailH;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: contentH,
        maxHeight: contentH,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final size = controller.isAttached ? controller.size : 0.0;
            final closedFraction = maxSize <= 0
                ? 0.0
                : (1 - (size / maxSize)).clamp(0.0, 1.0);
            return FractionalTranslation(
              translation: Offset(0, closedFraction),
              child: child!,
            );
          },
          child: child,
        ),
      ),
    );
  }

  List<TwitchMessage> _computeThreadMessages() {
    final root = _openThreadRoot;
    if (root == null) return const [];
    final channel = root.channel;
    if (channel == null) return const [];
    final allMsgs = _channelMessages[channel] ?? [];

    final byId = <String, TwitchMessage>{};
    final childrenOf = <String, List<TwitchMessage>>{};
    for (final m in allMsgs) {
      if (m.messageId != null) byId[m.messageId!] = m;
      final pid = m.replyToParentId;
      if (pid != null) {
        (childrenOf.putIfAbsent(pid, () => [])).add(m);
      }
    }

    final visited = <String>{};
    final threadMsgs = <TwitchMessage>[];
    final queue = <String>[];
    if (root.messageId != null) queue.add(root.messageId!);

    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      if (!visited.add(id)) continue;
      final msg = byId[id];
      if (msg != null) threadMsgs.add(msg);
      final children = childrenOf[id];
      if (children != null) {
        for (final child in children) {
          if (child.messageId != null) queue.add(child.messageId!);
        }
      }
    }

    threadMsgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return threadMsgs;
  }

  void _showUserProfile(
    String username,
    String? userId, {
    String? displayName,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => UserProfileSheet(
        username: username,
        displayName: displayName ?? username,
        userId: userId,
        twitchAuth: widget.twitchAuth,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _showEmoteSheet(GenericEmote emote) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => EmoteSheet(
        emote: emote,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _onChannelChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    setState(() {
      _selectedChannel = channel;
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
      if (cleared > 0) {
        _unreadMentions -= cleared;
        if (_unreadMentions < 0) _unreadMentions = 0;
      }
      if (_activePanel == OverlayPanel.emotes) {
        _activePanel = OverlayPanel.closed;
      }
      _openThreadRoot = null;
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
    });
    _closePanel();
  }

  List<TwitchMessage> _messages(String channel) {
    return _channelMessages[channel] ?? [];
  }

  void _scanHistoryForMentions() {
    if (_mentionScanDone || _currentUserLogin == null) return;
    _mentionScanDone = true;
    final login = _currentUserLogin!.toLowerCase();
    for (final entry in _channelMessages.entries) {
      if (entry.key == _mentionsChannel) continue;
      for (final msg in entry.value) {
        if (msg.isSystem ||
            msg.isHighlighted ||
            msg.login.toLowerCase() == login) {
          continue;
        }
        final isReplyToMe =
            msg.replyToUser != null && msg.replyToUser!.toLowerCase() == login;
        if (isMention(msg.text, login) || isReplyToMe) {
          msg.isHighlighted = true;
          _channelMessages.putIfAbsent(_mentionsChannel, () => []);
          _channelMessages[_mentionsChannel]!.insert(0, msg);
        }
      }
    }
  }

  void _truncateChannelMessages(String channel) {
    _chatConn.truncateChannelMessages(channel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: _activePanel == OverlayPanel.closed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePanel();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final statusBarH = MediaQuery.of(context).padding.top;
                  if (bottomInset == 0) {
                    _emoteSheetBoxHeight = constraints.maxHeight;
                  }
                  final sheetBoxHeight =
                      (_emoteSheetBoxHeight ?? constraints.maxHeight) -
                      statusBarH;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Column(
                        children: [
                          SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                      'uuhChat',
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w400,
                                        color: null,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.add),
                                    tooltip: 'Join channel',
                                    onPressed: _addChannelDialog,
                                  ),
                                  ListenableBuilder(
                                    listenable: _chatVersion,
                                    builder: (context, _) => IconButton(
                                      icon: Icon(
                                        Icons.notifications_active,
                                        color: _unreadMentions > 0
                                            ? theme.colorScheme.error
                                            : null,
                                      ),
                                      tooltip: 'Mentions',
                                      onPressed: () {
                                        _unreadMentions = 0;
                                        _channelsWithUnreadMentions.clear();
                                        _unreadMentionsPerChannel.clear();
                                        if (mounted) setState(() {});
                                        if (_activePanel ==
                                            OverlayPanel.mentions) {
                                          _closePanel();
                                        } else {
                                          _showMentionsView();
                                        }
                                      },
                                    ),
                                  ),
                                  SettingsButton(
                                    twitchAuth: widget.twitchAuth,
                                    onThemeChanged: widget.onThemeChanged,
                                    channelNotifier: _channelNotifier,
                                    onLeaveChannel: _removeChannel,
                                    onAddChannel: _addChannel,
                                    onReorderChannels: _reorderChannels,
                                    onSettingsClosed: () {
                                      if (mounted) setState(() {});
                                      _chatConn.connect();
                                    },
                                    eventSubMessageStream: _eventSub.onMessage,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) {
                                _suggestionsNotifier.value = [];
                              },
                              child: _channels.isNotEmpty
                                  ? ListenableBuilder(
                                      listenable: _chatVersion,
                                      builder: (context, _) => TabbedLayout(
                                        tabs: _channels,
                                        selectedIndex: _channels.indexOf(
                                          _selectedChannel ?? '',
                                        ),
                                        onSelectedIndexChanged:
                                            _onChannelChanged,
                                        pageBuilder: (_, i) =>
                                            _buildChat(_channels[i]),
                                        tabBuilder: (_, i) {
                                          final channel = _channels[i];
                                          final selected =
                                              channel == _selectedChannel;
                                          final hasUnreadMention =
                                              _channelsWithUnreadMentions
                                                  .contains(channel);
                                          return Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Text(
                                                channel,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight:
                                                      selected ||
                                                          _channelsWithUnread
                                                              .contains(channel)
                                                      ? FontWeight.w600
                                                      : FontWeight.normal,
                                                  color: selected
                                                      ? theme
                                                            .colorScheme
                                                            .primary
                                                      : _channelsWithUnread
                                                            .contains(channel)
                                                      ? Colors.white
                                                      : null,
                                                ),
                                              ),
                                              if (hasUnreadMention && !selected)
                                                Positioned(
                                                  top: -2,
                                                  right: -4,
                                                  child: Container(
                                                    key: const Key(
                                                      'unread_mention_dot',
                                                    ),
                                                    width: 6,
                                                    height: 6,
                                                    decoration: BoxDecoration(
                                                      color: theme
                                                          .colorScheme
                                                          .error,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                    )
                                  : _buildEmpty(),
                            ),
                          ),
                        ],
                      ),
                      // Thread sheet — always mounted, full height below status bar.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          ignoring: _activePanel != OverlayPanel.thread,
                          child: _buildSheetPanel(
                            ratio: _threadSheetRatio,
                            child: RepaintBoundary(
                              child: Material(
                                color: Theme.of(
                                  context,
                                ).scaffoldBackgroundColor,
                                clipBehavior: Clip.hardEdge,
                                child: Column(
                                  children: [
                                    _buildPanelDragHandle(
                                      ratio: _threadSheetRatio,
                                      maxSize: _fullHeightFraction,
                                      onClose: _closePanel,
                                      onSnap: () => _animateRatio(
                                        _threadSheetRatio,
                                        _threadSheetRatio.value,
                                        _fullHeightFraction,
                                        _sheetAnimDuration,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.close),
                                            tooltip: 'Close reply thread',
                                            onPressed: _closePanel,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              'Reply Thread',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Divider(
                                      height: 1,
                                      color: Theme.of(context).dividerColor,
                                    ),
                                    Expanded(
                                      child: ThreadPanelWidget(
                                        key: const ValueKey('thread_panel'),
                                        data: _threadPanelData,
                                        uiScale: 1.0,
                                        onLongPress: _showThreadMessageMenu,
                                        buildBadgeSpans: _buildBadgeSpans,
                                        buildMessageSpans: _buildMessageSpans,
                                        scrollController:
                                            _threadPanelScrollCtrl,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Mentions sheet — always mounted, full height below
                      // status bar.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          ignoring: _activePanel != OverlayPanel.mentions,
                          child: _buildSheetPanel(
                            ratio: _mentionsSheetRatio,
                            child: RepaintBoundary(
                              child: Material(
                                color: Theme.of(
                                  context,
                                ).scaffoldBackgroundColor,
                                clipBehavior: Clip.hardEdge,
                                child: Column(
                                  children: [
                                    _buildPanelDragHandle(
                                      ratio: _mentionsSheetRatio,
                                      maxSize: _fullHeightFraction,
                                      onClose: _closePanel,
                                      onSnap: () => _animateRatio(
                                        _mentionsSheetRatio,
                                        _mentionsSheetRatio.value,
                                        _fullHeightFraction,
                                        _sheetAnimDuration,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.arrow_back),
                                            tooltip: 'Back',
                                            onPressed: _closePanel,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              'Mentions / Whispers',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Divider(
                                      height: 1,
                                      color: Theme.of(context).dividerColor,
                                    ),
                                    Expanded(
                                      child: MentionsPanelWidget(
                                        key: const ValueKey('mentions_panel'),
                                        messages: _mentionsPanelData,
                                        uiScale: 1.0,
                                        buildBadgeSpans: _buildBadgeSpans,
                                        buildMessageSpans: _buildMessageSpans,
                                        scrollController:
                                            _mentionsPanelScrollCtrl,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Emote sheet — always mounted, always 60%.
                      // Box height is fixed (captured without keyboard);
                      // bottom: 0 stays anchored to the Stack's bottom edge
                      // which already moves up when the keyboard shrinks
                      // the Expanded area (same as the input below it).
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: sheetBoxHeight,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final totalAvailH = constraints.maxHeight;
                            return IgnorePointer(
                              ignoring: _activePanel != OverlayPanel.emotes,
                              child: DraggableScrollableSheet(
                                controller: _emoteSheetCtrl,
                                initialChildSize: 0,
                                minChildSize: 0,
                                maxChildSize: _emoteMaxFraction,
                                snap: true,
                                builder: (context, scrollController) {
                                  final sheetTheme = Theme.of(context);
                                  return _buildSlideUpContent(
                                    controller: _emoteSheetCtrl,
                                    totalAvailH: totalAvailH,
                                    maxSize: _emoteMaxFraction,
                                    child: RepaintBoundary(
                                      child: Material(
                                        color:
                                            sheetTheme.scaffoldBackgroundColor,
                                        child: EmoteMenuPanelWidget(
                                          key: const ValueKey('emote_panel'),
                                          isActive:
                                              _activePanel ==
                                              OverlayPanel.emotes,
                                          uiScale: 1.0,
                                          selectedChannel: _selectedChannel,
                                          onEmoteSelected: _onEmoteSelected,
                                          onClose: _closePanel,
                                          emoteManager: _emoteManager,
                                          scrollController: scrollController,
                                          sheetCtrl: _emoteSheetCtrl,
                                          emoteMaxFraction: _emoteMaxFraction,
                                          sheetAnimDuration: _sheetAnimDuration,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),

                      // Autocomplete dropdown — floats above chat, anchored just
                      // above the message input, 60% width like DankChat's popup.
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: SizedBox(
                          width: (MediaQuery.of(context).size.width * 0.6)
                              .clamp(0.0, 340.0),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.25,
                            ),
                            child: ValueListenableBuilder<List<Suggestion>>(
                              valueListenable: _suggestionsNotifier,
                              builder: (_, suggestions, _) =>
                                  AutocompleteDropdown(
                                    suggestions: suggestions,
                                    onSelect: _onSuggestionSelected,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MessageInput(
                    controller: _messageController,
                    focusNode: _focusNode,
                    onSend: _sendMessage,
                    onSendLongPress: _onSendLongPress,
                    onEmoteToggle: () {
                      if (_activePanel == OverlayPanel.emotes) {
                        _closePanel();
                      } else {
                        _showEmoteMenu();
                      }
                    },
                    replyToMsg: _replyToMsg,
                    onCancelReply: () => setState(() => _replyToMsg = null),
                    enabled:
                        _activePanel != OverlayPanel.mentions &&
                        widget.twitchAuth.isConfigured,
                    hintText: !widget.twitchAuth.isConfigured
                        ? 'Connect an account to chat'
                        : _activePanel == OverlayPanel.thread
                        ? 'Reply to thread...'
                        : _activePanel == OverlayPanel.mentions
                        ? 'Type a message...'
                        : null,
                  ),
                    ListenableBuilder(
                      listenable: _chatVersion,
                      builder: (context, _) {
                        final status = _chatStatus[_selectedChannel];
                        final hasStatus = status != null && status.isNotEmpty;
                        return AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          alignment: Alignment.topCenter,
                          child: hasStatus
                              ? Padding(
                                  padding: const EdgeInsets.only(
                                    left: 12,
                                    right: 12,
                                    bottom: 4,
                                  ),
                                  child: Text(
                                    status,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    if (!widget.twitchAuth.isConfigured) {
      return const Center(
        child: Text('Configure Twitch credentials in Settings first'),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('Press + to join a channel'),
        ],
      ),
    );
  }

  List<InlineSpan> _buildMessageSpans(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored = false,
    double textScale = 1.0,
  }) {
    msg.cachedSpans ??= _computeMessageSpans(msg, channel, scale: textScale);
    if (colored) {
      return [
        ...msg.cachedSpans!.map((span) {
          if (span is TextSpan) {
            return TextSpan(
              text: span.text,
              style: TextStyle(
                fontSize: 14 * textScale,
                color: parseColor(msg.color, background: surface),
                decoration: TextDecoration.none,
              ),
              recognizer: span.recognizer,
            );
          }
          return span;
        }),
      ];
    }
    return msg.cachedSpans!;
  }

  List<InlineSpan> _computeMessageSpans(
    TwitchMessage msg,
    String channel, {
    double scale = 1.0,
  }) {
    final channelEmotes = _emoteManager.byCode(channel);
    return EmoteText.build(
      text: msg.text,
      twitchPositions: msg.emotePositions,
      channelEmotes: channelEmotes,
      onEmoteTap: _showEmoteSheet,
      scale: scale,
    );
  }

  List<WidgetSpan> _buildBadgeSpans(
    String channel,
    TwitchMessage msg, {
    double badgeScale = 1.0,
  }) {
    final badgeSize = 18.0 * badgeScale;
    final spans = <WidgetSpan>[];

    // Shared chat source badge (circular avatar, prepended)
    if (msg.sourceBroadcasterId != null) {
      final avatarUrl = _badgeService.resolveChannelAvatar(
        msg.sourceBroadcasterId!,
      );
      if (avatarUrl != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: msg.sourceBroadcasterName ?? 'shared chat',
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: ClipOval(
                  child: CachedNetworkImage(
                    imageUrl: avatarUrl,
                    width: badgeSize,
                    height: badgeSize,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, _) =>
                        SizedBox(width: badgeSize, height: badgeSize),
                    errorWidget: (_, url, error) {
                      debugPrint(
                        'Shared chat badge image failed: $url — $error',
                      );
                      return SizedBox(width: badgeSize, height: badgeSize);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    // Standard badges
    final badges = msg.badges;
    if (badges != null) {
      for (final badge in badges) {
        final url = _badgeService.resolveBadgeUrl(
          channel,
          badge.setId,
          badge.versionId,
        );
        if (url == null) continue;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: badge.setId,
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: CachedNetworkImage(
                  imageUrl: url,
                  width: badgeSize,
                  height: badgeSize,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) =>
                      SizedBox(width: badgeSize, height: badgeSize),
                  errorWidget: (_, url, error) {
                    debugPrint('Badge image load failed: $url — $error');
                    return SizedBox(width: badgeSize, height: badgeSize);
                  },
                ),
              ),
            ),
          ),
        );
      }
    }
    return spans;
  }

  Widget _buildChat(String channel) {
    final msgs = _frozenSnapshot[channel] ?? _messages(channel);
    final surface = Theme.of(context).colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = 1.0 * systemScale;
    final atBottom = _isAtBottom[channel] ?? true;

    if (msgs.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              final scrolledUp = notification.metrics.pixels > 50.0;
              if (scrolledUp && (_isAtBottom[channel] ?? true)) {
                _isAtBottom[channel] = false;
                _frozenSnapshot[channel] = List.of(
                  _channelMessages[channel] ?? [],
                );
                _chatVersion.value++;
              } else if (!scrolledUp && !(_isAtBottom[channel] ?? true)) {
                _isAtBottom[channel] = true;
                _frozenSnapshot.remove(channel);
                _chatVersion.value++;
              }
            }
            return false;
          },
          child: ScrollbarTheme(
            data: const ScrollbarThemeData(
              thickness: WidgetStatePropertyAll(0),
            ),
            child: ListView.builder(
              key: ValueKey(channel),
              controller: _scrollCtrl(channel),
              reverse: true,
              itemCount: msgs.length,
              itemBuilder: (_, i) {
                final msg = msgs[i];

                final key = msg.messageId != null
                    ? _messageKeys.putIfAbsent(
                        '$channel:${msg.messageId}',
                        () => GlobalKey(),
                      )
                    : null;

                Widget body;
                if (msg.isSystem) {
                  body = ChatMessageTile(
                    message: msg,
                    channel: channel,
                    surface: surface,
                    textScale: s,
                    buildBadgeSpans: _buildBadgeSpans,
                    buildMessageSpans: _buildMessageSpans,
                    systemBodyBuilder: (msg, scale) =>
                        parseTextWithLinks(msg.text),
                  );
                } else {
                  body = ChatMessageTile(
                    message: msg,
                    channel: channel,
                    surface: surface,
                    textScale: s,
                    buildBadgeSpans: _buildBadgeSpans,
                    buildMessageSpans: _buildMessageSpans,
                    onTapUser: (login, userId) => _showUserProfile(
                      login,
                      userId,
                      displayName: msg.displayName,
                    ),
                    onLongPress: () => _showMessageMenu(msg),
                    replyIndicator: msg.replyToUser != null
                        ? _buildReplyIndicator(msg)
                        : null,
                  );
                }

                if (key != null) {
                  body = Container(key: key, child: body);
                }
                return body;
              },
            ),
          ),
        ),
        if (!atBottom)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'scroll_down_$channel',
              onPressed: () {
                _isAtBottom[channel] = true;
                _frozenSnapshot.remove(channel);
                _scrollCtrl(channel).jumpTo(0);
                _chatVersion.value++;
              },
              child: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
      ],
    );
  }

  Widget _buildReplyIndicator(TwitchMessage msg) {
    final replyPreview = msg.replyToText ?? '';
    final preview = replyPreview.length > 60
        ? '${replyPreview.substring(0, 60)}…'
        : replyPreview;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2),
      child: GestureDetector(
        onTap: () {
          final root = _findThreadRoot(msg);
          if (root != null) _showThreadView(root);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 14,
              color: Colors.grey[500],
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'replying to ${msg.replyToUser ?? 'unknown'}: $preview',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool isMention(String text, String login) {
  final words = text.split(RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+'));
  for (final w in words) {
    final lower = w.toLowerCase();
    if (lower == '@$login' || lower == login) return true;
  }
  return false;
}
