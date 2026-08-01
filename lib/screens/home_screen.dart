import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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
import '../util/mention.dart';
import '../util/thread_utils.dart';
import '../widgets/settings.dart';
import '../widgets/tabbed_layout.dart';
import '../services/user_store.dart';
import '../services/suggestion.dart';
import '../services/notification_service.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/user_profile_sheet.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/message_input.dart';
import '../widgets/thread_panel.dart';
import '../widgets/mentions_panel.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/foreground_task.dart';

enum OverlayPanel { closed, thread, mentions, emotes }

class HomeScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;
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
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
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
  static const _defaultAltPings = <String>[];

  List<String> _altPings = _defaultAltPings;

  late final _connectivity = Connectivity();
  late final _eventSub =
      widget.eventSubService ?? EventSubService(connectivity: _connectivity);
  late final _irc =
      widget.ircService ?? IrcService(connectivity: _connectivity);
  late final _ircRead =
      widget.ircReadService ?? IrcReadService(connectivity: _connectivity);
  late final _recentMessages =
      widget.recentMessagesService ?? RecentMessagesService();
  late final _sevenTvClient =
      widget.sevenTvEventClient ??
      SevenTvEventClient(connectivity: _connectivity);
  late final _twitchApi = TwitchApi();
  late final _chatConn = ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: _twitchApi,
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
      lastTypedText: _lastTypedText,
      lastSentWireText: _lastSentWireText,
      ownMessageIds: _ownMessageIds,
      bumpChannel: _notifyNewMessage,
      invalidateChannel: _bumpChannel,
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
        unawaited(_ensureBlockedUsersLoaded());
      },
      getCurrentUserId: () => _currentUserId,
      setCurrentUserId: (v) => _currentUserId = v,
      onCommand: _handleCommand,
      getReplyToMsg: () => _replyToMsg,
      setReplyToMsg: (v) => _replyToMsg = v,
      isChatReady: () => _blocksReady,
      isBlocked: (login) => _blockedLogins.contains(login.toLowerCase()),
      onRequestFocus: () => _focusNode.requestFocus(),
      getAltPings: () => _altPings,
      onShowSnackBar: (msg) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
      },
    ),
  );
  late final _messageBuilder = MessageBuilder(
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    onShowEmoteSheet: _showEmoteSheet,
  );
  late final _commandHandler = CommandHandler(
    twitchApi: _twitchApi,
    irc: _irc,
    getChannelUserIds: () => _channelUserIds,
    getCurrentUserId: () => _currentUserId,
    getCurrentUserLogin: () => _currentUserLogin,
    addSystemMessage: _addSystemMessage,
  );
  final _messageController = TextEditingController();
  final _focusNode = FocusNode();

  final _notificationService = NotificationService();
  StreamSubscription<String>? _notificationTapSub;
  var _isBackgrounded = false;

  late final _emoteManager = EmoteManager(
    probe: _connectivity.checkConnectivity,
  );
  final _badgeService = TwitchBadgeService();
  final _userStore = UserStore();
  final _channels = <String>[];
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _chatVersions = <String, ValueNotifier<int>>{};
  final _messageNotifiers = <String, ValueNotifier<int>>{};
  final _tileCache = <String, Map<String?, Widget>>{};
  final _mentionsBump = ValueNotifier(0);
  final _statusBump = ValueNotifier(0);
  String? _selectedChannel;
  final _channelMessages = <String, List<TwitchMessage>>{};
  final _blockedLogins = <String>{};
  bool _blocksReady = false;
  bool _blocksFetched = false;
  bool _channelsLoaded = false;
  final _scrollControllers = <String, ScrollController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};
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
  bool _replyToRoot = false;
  OverlayPanel _activePanel = OverlayPanel.closed;
  int _maxMessagesPerChannel = 200;
  int _nextSystemMessageId = 0;

  final _suggestionsNotifier = ValueNotifier<List<Suggestion>>([]);
  final _selectedTabIndex = ValueNotifier<int>(0);

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

  String? _currentUserLogin;
  bool _mentionScanDone = false;
  String? _currentUserId;
  String? _lastSentText;
  final Map<String, String> _lastTypedText = {};
  final Map<String, String> _lastSentWireText = {};

  ({int start, String originalText, String replacementText})? _lastAutoUndo;
  String? _previousTextForUndo;
  String? _undoExpectedAfter;

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
    _mentionsBump.addListener(_onPanelDataChanged);
    if (Platform.isAndroid) {
      _notificationService.init();
      _notificationTapSub = _notificationService.onNotificationTap.listen(
        _onNotificationTap,
      );
      final pendingChannel = _notificationService.pendingLaunchChannel;
      if (pendingChannel != null) {
        _navigateToChannel(pendingChannel);
      }
      _notificationService.clearMentionNotifications();
      _chatConn.onMention = _onMentionNotification;
    }
    _loadMaxMessages();
    _ensureBlockedUsersLoaded();
    _loadAltPings();
    _chatConn.connect();
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _emoteManager.preloadGlobalEmotes();
    _emoteManager.addListener(_onEmotesChanged);
    _badgeService.fetchGlobalBadges(widget.twitchAuth);
    widget.twitchAuth.addListener(_onAuthChanged);
    _focusNode.addListener(_onInputFocusChanged);
    _messageController.addListener(_onInputChanged);
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) _initForegroundService();
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isBackgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        startForegroundService(List.of(_channels));
      } else if (state == AppLifecycleState.resumed) {
        stopForegroundService();
        _notificationService.clearMentionNotifications();
      }
    }
    if (state == AppLifecycleState.resumed) {
      _chatConn.reconnectIfNecessary();
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
    if (_selectedChannel != null) {
      final newIdx = _channels.indexOf(_selectedChannel!);
      if (newIdx >= 0) _selectedTabIndex.value = newIdx;
    }
    _saveChannels();
  }

  // Fetch the account's Twitch block list before anything is shown so blocked
  // users never appear — not even briefly. Fail-open: chat shows normally if
  // the fetch fails, and a later login triggers a (guarded) retry.
  Future<void> _ensureBlockedUsersLoaded() async {
    if (_blocksFetched) return;
    final userId = widget.twitchAuth.userId;
    if (userId == null) {
      _blocksReady = true;
      _loadChannels();
      return;
    }
    _blocksFetched = true;
    try {
      final blocked = await _twitchApi
          .getBlockedUsers(widget.twitchAuth)
          .timeout(const Duration(seconds: 5));
      _blockedLogins.addAll(blocked);
    } catch (e) {
      debugPrint('[HomeScreen] failed to fetch blocked users: $e');
    }
    if (!mounted) return;
    _blocksReady = true;
    _sweepBlockedMessages();
    _loadChannels();
    setState(() {});
  }

  void _sweepBlockedMessages() {
    for (final entry in _channelMessages.entries) {
      final msgs = entry.value;
      final before = msgs.length;
      msgs.removeWhere(
        (m) => !m.isSystem && _blockedLogins.contains(m.login.toLowerCase()),
      );
      if (msgs.length != before) _bumpChannel(entry.key);
    }
  }

  void _onUserBlocked(String login) {
    _blockedLogins.add(login.toLowerCase());
    _sweepBlockedMessages();
  }

  Future<void> _loadChannels() async {
    if (_channelsLoaded) return;
    _channelsLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('channels');
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (_channels.contains(name)) continue;
      _channels.add(name);
      _channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
    }
    _channelNotifier.value = List.of(_channels);
    _selectedChannel = _channels.first;
    _selectedTabIndex.value = 0;
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
                  if (!msg.isSystem && msg.login.isNotEmpty) {
                    final preferred =
                        msg.displayName.toLowerCase() == msg.login.toLowerCase()
                        ? msg.displayName
                        : msg.login;
                    _userStore.addUser(name, preferred);
                  }
                  final isNew =
                      msg.messageId == null ||
                      !existingIds.contains(msg.messageId);
                  if (isNew) {
                    if (msg.isSystem && _currentUserLogin != null) {
                      final selfLogin = _currentUserLogin!.toLowerCase();
                      if (msg.login.toLowerCase() == selfLogin) {
                        msg.text = msg.text.replaceFirst(
                          RegExp(
                            RegExp.escape(msg.login),
                            caseSensitive: false,
                          ),
                          'You',
                        );
                        msg.text = msg.text.replaceFirst('was', 'were');
                      }
                    }
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
                _bumpChannel(name);
                _moveConnectedMessageToTop(name);
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
    _checkAutocompleteUndo();

    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final word = getCurrentWord(text, cursor);
    var filterWord = word.text;
    if (filterWord.startsWith('@') && filterWord.length >= 2) {
      filterWord = filterWord.substring(1);
    }
    if (filterWord.length < 2) {
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
      _previousTextForUndo = _messageController.text;
      return;
    }
    final channel = _selectedChannel;
    if (channel == null) {
      _previousTextForUndo = _messageController.text;
      return;
    }
    final users = _userStore.usersForChannel(channel);
    final isMention = word.text.startsWith('@');
    final emotes = isMention
        ? <GenericEmote>[]
        : [
            ...?_emoteManager.byCode(channel)?.suggestions,
            // Subscriber emotes are global — usable in every channel, not
            // just the one they belong to.
            ..._emoteManager.subscriberEmotesByChannel().values.expand(
              (e) => e,
            ),
          ];
    final filtered = filterSuggestions(
      word: filterWord,
      emotes: emotes,
      users: users,
    );
    _suggestionsNotifier.value = filtered;
    _previousTextForUndo = _messageController.text;
  }

  void _onSuggestionSelected(Suggestion suggestion) {
    var replacement = switch (suggestion) {
      UserSuggestion() => suggestion.displayName,
      EmoteSuggestion() => suggestion.emote.code,
    };

    final textBefore = _messageController.text;
    final cursorBefore = _messageController.selection.baseOffset;
    final wordBefore = getCurrentWord(textBefore, cursorBefore);

    if (suggestion is UserSuggestion) {
      if (wordBefore.text.startsWith('@')) {
        replacement = '@$replacement';
      }
    }

    final trailingSpace =
        wordBefore.end < textBefore.length && textBefore[wordBefore.end] == ' '
        ? ''
        : ' ';

    _lastAutoUndo = (
      start: wordBefore.start,
      originalText: wordBefore.text,
      replacementText: replacement + trailingSpace,
    );

    replaceCurrentWord(_messageController, replacement);

    final replEnd =
        wordBefore.start + replacement.length + trailingSpace.length;
    _undoExpectedAfter = _messageController.text.length > replEnd
        ? _messageController.text.substring(replEnd)
        : '';

    if (suggestion is EmoteSuggestion) {
      _emoteManager.markEmoteUsed(suggestion.emote);
    }
    _suggestionsNotifier.value = [];
    _focusNode.requestFocus();
  }

  // Detect a single backspace immediately after autocomplete and restore the
  // original typed text. Five sequential guards verify no other edits occurred.
  void _checkAutocompleteUndo() {
    final undo = _lastAutoUndo;
    if (undo == null) return;
    final prev = _previousTextForUndo;
    if (prev == null) return;

    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final replacementLen = undo.replacementText.length;
    final replEnd = undo.start + replacementLen;

    final minLen = text.length < replEnd ? text.length : replEnd;
    for (var i = undo.start; i < minLen; i++) {
      if (text.codeUnitAt(i) !=
          undo.replacementText.codeUnitAt(i - undo.start)) {
        _lastAutoUndo = null;
        _undoExpectedAfter = null;
        return;
      }
    }

    // Verify text after the replacement hasn't changed.
    final currentAfter = text.length > replEnd ? text.substring(replEnd) : '';
    final expectedAfter = _undoExpectedAfter ?? '';
    if (currentAfter != expectedAfter) {
      _lastAutoUndo = null;
      _undoExpectedAfter = null;
      return;
    }

    // Must be a single backspace.
    if (text.length != prev.length - 1) return;

    // Cursor must be right after the shortened replacement.
    if (cursor != replEnd - 1) return;

    // Region must match replacement minus its last char.
    final regionEnd = replEnd - 1;
    if (text.length < regionEnd) return;
    if (text.substring(undo.start, regionEnd) !=
        undo.replacementText.substring(0, replacementLen - 1)) {
      return;
    }

    // All checks passed. Undo.
    final before = text.substring(0, undo.start);
    final after = text.substring(regionEnd);
    _lastAutoUndo = null;
    _undoExpectedAfter = null;
    _messageController.value = TextEditingValue(
      text: before + undo.originalText + after,
      selection: TextSelection.collapsed(
        offset: undo.start + undo.originalText.length,
      ),
    );
  }

  void _onEmotesChanged() {
    final channel = _emoteManager.consumeChangedChannel();
    if (channel != null) {
      final msgs = _channelMessages[channel];
      if (msgs != null) {
        for (final msg in msgs) {
          msg.cachedSpans = null;
        }
      }
    } else {
      for (final msgs in _channelMessages.values) {
        for (final msg in msgs) {
          msg.cachedSpans = null;
        }
      }
    }
    if (channel != null) {
      _bumpChannel(channel);
    } else {
      _mentionsBump.value++;
    }
  }

  ValueNotifier<int> _versionNotifier(String channel) {
    return _chatVersions.putIfAbsent(channel, () => ValueNotifier(0));
  }

  ValueNotifier<int> _messageNotifier(String channel) {
    return _messageNotifiers.putIfAbsent(channel, () => ValueNotifier(0));
  }

  ValueNotifier<bool> _atBottomNotifier(String channel) {
    return _atBottomNotifiers.putIfAbsent(channel, () => ValueNotifier(true));
  }

  void _notifyNewMessage(String channel) {
    _messageNotifier(channel).value++;
    _mentionsBump.value++;
  }

  void _bumpChannel(String channel) {
    _tileCache.remove(channel);
    _versionNotifier(channel).value++;
    _mentionsBump.value++;
  }

  void _onPanelDataChanged() {
    if (_activePanel == OverlayPanel.closed) return;
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
    _chatConn.connect();
  }

  Future<void> _refreshEmotesAfterAuth() async {
    try {
      for (final channel in _channels) {
        final userId = await _twitchApi.getUserId(widget.twitchAuth, channel);
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
      unawaited(
        _loadUserTwitchEmotes().catchError(
          (e) => debugPrint('_loadUserTwitchEmotes failed: $e'),
        ),
      );
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
      final resolved = await _twitchApi.getUserLoginsByIds(auth, unknownIds);
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
      _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
    });
  }

  void _loadAltPings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _altPings = prefs.getStringList('alt_pings') ?? _defaultAltPings;
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
    _mentionsBump.removeListener(_onPanelDataChanged);
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
    for (final n in _chatVersions.values) {
      n.dispose();
    }
    for (final n in _messageNotifiers.values) {
      n.dispose();
    }
    for (final n in _atBottomNotifiers.values) {
      n.dispose();
    }
    _tileCache.clear();
    _mentionsBump.dispose();
    _statusBump.dispose();
    _notificationTapSub?.cancel();
    _notificationService.dispose();
    super.dispose();
  }

  // Dedup connection status messages: collapse "Connected to IRC" into
  // "Connected", convert "Disconnected" to "Reconnected" on immediate
  // reconnect. Prevents status line spam during reconnection storms.
  void _addSystemMessage(String channel, String text) {
    _channelMessages.putIfAbsent(channel, () => []);
    final msgs = _channelMessages[channel]!;
    if (msgs.isNotEmpty) {
      final newest = msgs.first;
      if (newest.isSystem) {
        final now = DateTime.now();
        final isRecent = now.difference(newest.timestamp).inMinutes < 1;
        if (text == 'Connected to IRC') {
          if (isRecent &&
              (newest.text == 'Connected' ||
                  newest.text == 'Connected to IRC')) {
            return;
          }
        } else if (text == 'Connected') {
          if (isRecent && newest.text == 'Connected') {
            return;
          }
          if (isRecent && newest.text == 'Connected to IRC') {
            newest.text = 'Connected';
            _bumpChannel(channel);
            return;
          }
          if (isRecent && newest.text == 'Disconnected') {
            newest.text = 'Reconnected';
            _bumpChannel(channel);
            return;
          }
        }
      }
    }
    msgs.insert(
      0,
      TwitchMessage(
        login: '',
        text: text,
        messageId: 'sys_${_nextSystemMessageId++}',
        isSystem: true,
        channel: channel,
      ),
    );
    _truncateChannelMessages(channel);
    _notifyNewMessage(channel);
  }

  void _showMessageMenu(TwitchMessage msg) {
    final threadRoot = _findThreadRoot(msg);
    final hasThread = threadRoot != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
      ),
    );
  }

  void _showThreadMessageMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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

  // "Connected" is emitted as soon as EventSub is up, which is usually before
  // the robotty history fetch completes. History messages are then inserted
  // above it, so move it back to the most recent position to stay visible.
  void _moveConnectedMessageToTop(String channel) {
    final msgs = _channelMessages[channel];
    if (msgs == null || msgs.length < 2) return;
    final idx = msgs.indexWhere((m) => m.isSystem && m.text == 'Connected');
    if (idx <= 0) return;
    final msg = msgs.removeAt(idx);
    msgs.insert(0, msg);
    _bumpChannel(channel);
  }

  Future<void> _addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _channels.contains(name)) return;

    setState(() {
      _channels.add(name);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
      _selectedChannel = name;
      _selectedTabIndex.value = _channels.length - 1;
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
              _bumpChannel(name);
              _moveConnectedMessageToTop(name);
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
    showJoinChannelDialog(context, onJoin: _addChannel);
  }

  void _removeChannel(String channel) {
    _chatConn.stopChatStatusTimer(channel);
    _irc.part(channel);
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _badgeService.clearChannel(channel);
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
        if (_channels.isNotEmpty) {
          _selectedTabIndex.value = _channels.length - 1;
        }
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
      final TwitchMessage? replyTo;
      if (_replyToRoot) {
        final rootId = threadRoot.replyThreadRootId ?? threadRoot.messageId;
        replyTo = threadMsgs.firstWhere(
          (m) => m.messageId == rootId,
          orElse: () => TwitchMessage(
            login: '',
            text: '',
            messageId: rootId,
            channel: channel,
          ),
        );
      } else {
        replyTo = threadMsgs.isNotEmpty ? threadMsgs.last : null;
      }
      _doSendMessage(text, channel, replyTo: replyTo);
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
  Future<void> _handleCommand(
    String text,
    String channel,
    TwitchAuth auth,
  ) async {
    try {
      await _commandHandler.handle(text, channel, auth);
    } catch (e) {
      debugPrint('[HomeScreen] command failed: $e');
      _addSystemMessage(channel, 'Command failed: $e');
    }
  }

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(channel, () => ScrollController());
  }

  // Walk the reply-parent chain to the root with cycle detection (visited set).
  // A message that has children is treated as root even if it has a parent
  // (handles nested reply scenarios).
  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    if (msg.replyThreadRootId != null) return msg;

    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = _channelMessages[channel];
    if (msgs == null) return null;

    if (msg.messageId != null &&
        msgs.any((m) => m.replyToParentId == msg.messageId)) {
      return msg;
    }

    if (msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null &&
        visited.add(current.replyToParentId!)) {
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
    _focusNode.unfocus();
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
                MediaQuery.of(context).padding.top -
                MediaQuery.viewInsetsOf(context).bottom);
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
    final entry = _openThreadRoot;
    if (entry == null) return const [];
    final channel = entry.channel;
    if (channel == null) return const [];
    final allMsgs = _channelMessages[channel] ?? [];

    final entryKey = entry.replyThreadRootId ?? entry.messageId;
    if (entryKey == null) return const [];

    final parentOf = <String, String>{};
    for (final m in allMsgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    String threadKeyFor(TwitchMessage m) {
      if (m.replyThreadRootId != null) return m.replyThreadRootId!;
      if (m.messageId != null && parentOf.containsKey(m.messageId)) {
        return resolveThreadRootId(m.messageId!, parentOf);
      }
      return m.messageId ?? '';
    }

    final resolvedKey = threadKeyFor(entry);

    final threadMsgs = allMsgs
        .where((m) => threadKeyFor(m) == resolvedKey)
        .toList();

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
        twitchApi: _twitchApi,
        twitchAuth: widget.twitchAuth,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
        onUserBlocked: _onUserBlocked,
      ),
    );
  }

  void _showEmoteSheet(List<GenericEmote> emotes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => EmoteSheet(
        emotes: emotes,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _onMentionNotification(String channel, TwitchMessage msg) {
    if (!_isBackgrounded) return;
    if (msg.isHistory) return;
    _notificationService.showMentionNotification(
      channel: channel,
      userName: msg.displayName,
      message: msg.text,
    );
  }

  void _onNotificationTap(String channel) {
    _navigateToChannel(channel);
  }

  void _navigateToChannel(String channel) {
    final index = _channels.indexOf(channel);
    if (index >= 0) {
      _onChannelChanged(index);
    }
  }

  void _onChannelFocusChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    _closePanel();
    _selectedChannel = channel;
    _channelsWithUnread.remove(channel);
    _channelsWithUnreadMentions.remove(channel);
    final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
    if (cleared > 0) {
      _unreadMentions -= cleared;
      if (_unreadMentions < 0) _unreadMentions = 0;
    }
    _openThreadRoot = null;
    if (_suggestionsNotifier.value.isNotEmpty) {
      _suggestionsNotifier.value = [];
    }
    _selectedTabIndex.value = index;
  }

  void _onChannelChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    _closePanel();
    setState(() {
      _selectedChannel = channel;
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
      if (cleared > 0) {
        _unreadMentions -= cleared;
        if (_unreadMentions < 0) _unreadMentions = 0;
      }
      _openThreadRoot = null;
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
    });
    _selectedTabIndex.value = index;
  }

  // Retroactive mention scan: runs once on login. Messages inserted at front
  // of mentions channel in scan order (reverse-chronological within each
  // channel), so they appear newest-first but may not be perfectly sorted.
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

    return PopScope(
      canPop: _activePanel == OverlayPanel.closed && !_focusNode.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_activePanel != OverlayPanel.closed) {
          _closePanel();
        } else {
          _focusNode.unfocus();
          setState(() {});
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final statusBarH = MediaQuery.of(context).padding.top;
                  if (MediaQuery.viewInsetsOf(context).bottom == 0) {
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
                                      'ErmChat',
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
                                    listenable: _mentionsBump,
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
                                    onThemeChanged: (mode) {
                                      _tileCache.clear();
                                      widget.onThemeChanged(mode);
                                    },
                                    keepScreenOn: widget.keepScreenOn,
                                    onKeepScreenOnChanged:
                                        widget.onKeepScreenOnChanged,
                                    channelNotifier: _channelNotifier,
                                    onLeaveChannel: _removeChannel,
                                    onAddChannel: _addChannel,
                                    onReorderChannels: _reorderChannels,
                                    onSettingsOpened: () =>
                                        _focusNode.unfocus(),
                                    onSettingsClosed: () {
                                      _loadAltPings();
                                      _loadMaxMessages();
                                      if (mounted) setState(() {});
                                    },
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
                                  ? TabbedLayout(
                                      tabs: _channels,
                                      selectedIndex: _channels.indexOf(
                                        _selectedChannel ?? '',
                                      ),
                                      onSelectedIndexChanged: _onChannelChanged,
                                      onFocusChanged: _onChannelFocusChanged,
                                      pageBuilder: (_, i) {
                                        final channel = _channels[i];
                                        return ListenableBuilder(
                                          listenable: _versionNotifier(channel),
                                          builder: (_, _) => ChatView(
                                            channel: channel,
                                            messages:
                                                _channelMessages[channel] ?? [],
                                            frozenSnapshot: _frozenSnapshot,
                                            tileCache: _tileCache,
                                            atBottomNotifier: _atBottomNotifier(
                                              channel,
                                            ),
                                            messageNotifier: _messageNotifier(
                                              channel,
                                            ),
                                            scrollController: _scrollCtrl(
                                              channel,
                                            ),
                                            messageBuilder: _messageBuilder,
                                            onShowUserProfile:
                                                (
                                                  login,
                                                  userId, {
                                                  displayName,
                                                }) => _showUserProfile(
                                                  login,
                                                  userId,
                                                  displayName: displayName,
                                                ),
                                            onShowMessageMenu: _showMessageMenu,
                                            onNewMessage: _notifyNewMessage,
                                            onFindThreadRoot: _findThreadRoot,
                                            onShowThreadView: _showThreadView,
                                          ),
                                        );
                                      },
                                      focusOnHalfDrag: true,
                                      tabBuilder: (_, i) {
                                        final channel = _channels[i];
                                        return ListenableBuilder(
                                          listenable: Listenable.merge([
                                            _selectedTabIndex,
                                            _mentionsBump,
                                          ]),
                                          builder: (ctx, _) {
                                            final focused =
                                                i == _selectedTabIndex.value;
                                            final selected =
                                                focused ||
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
                                                                .contains(
                                                                  channel,
                                                                )
                                                        ? FontWeight.w600
                                                        : FontWeight.normal,
                                                    color: selected
                                                        ? theme
                                                              .colorScheme
                                                              .primary
                                                        : _channelsWithUnread
                                                              .contains(channel)
                                                        ? theme
                                                              .colorScheme
                                                              .onSurface
                                                        : null,
                                                  ),
                                                ),
                                                if (hasUnreadMention &&
                                                    !selected)
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
                                        );
                                      },
                                    )
                                  : _buildEmpty(),
                            ),
                          ),
                        ],
                      ),
                      // Thread sheet — offstage when closed to avoid layout cost.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Offstage(
                          offstage: _activePanel != OverlayPanel.thread,
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
                                        buildBadgeSpans:
                                            _messageBuilder.buildBadgeSpans,
                                        buildMessageSpans:
                                            _messageBuilder.buildMessageSpans,
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
                      // Mentions sheet — offstage when closed to avoid layout cost.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Offstage(
                          offstage: _activePanel != OverlayPanel.mentions,
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
                                        buildBadgeSpans:
                                            _messageBuilder.buildBadgeSpans,
                                        buildMessageSpans:
                                            _messageBuilder.buildMessageSpans,
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
            Builder(
              builder: (ctx) {
                final inset = MediaQuery.viewInsetsOf(ctx).bottom;
                final pad = MediaQuery.paddingOf(ctx).bottom;
                return Padding(
                  padding: EdgeInsets.only(bottom: inset + pad),
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
                          onTap: () => _suggestionsNotifier.value = [],
                          onEmoteToggle: () {
                            if (_activePanel == OverlayPanel.emotes) {
                              _closePanel();
                            } else {
                              _showEmoteMenu();
                            }
                          },
                          replyToMsg: _replyToMsg,
                          onCancelReply: () =>
                              setState(() => _replyToMsg = null),
                          enabled:
                              _activePanel != OverlayPanel.mentions &&
                              widget.twitchAuth.isConfigured &&
                              _chatConn.connectionStatus ==
                                  EventSubStatus.connected,
                          hintText: !widget.twitchAuth.isConfigured
                              ? 'Connect an account to chat'
                              : _chatConn.connectionStatus !=
                                    EventSubStatus.connected
                              ? 'Disconnected'
                              : _activePanel == OverlayPanel.thread
                              ? 'Reply to thread...'
                              : _activePanel == OverlayPanel.mentions
                              ? 'Type a message...'
                              : null,
                        ),
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            _mentionsBump,
                            _selectedTabIndex,
                          ]),
                          builder: (context, _) {
                            final status = _chatStatus[_selectedChannel];
                            final hasStatus =
                                status != null && status.isNotEmpty;
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
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
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
                );
              },
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          const Text('Press + to join a channel'),
        ],
      ),
    );
  }
}
