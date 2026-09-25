import 'package:ermchat/channels/channel_manager.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/composer/composer_controller.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/threads.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/chat_history_controller.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/emote_store.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/notification_service.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/stream_player_controller.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/irc/transport/read.dart';
import 'package:ermchat/irc/transport/write.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/widgets/broadcast_widgets.dart';
import 'package:ermchat/chat/channel/info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChannelManagerHost implements ChannelManagerHost {
  @override
  String? selectedChannel = 'test';
  @override
  String? get sessionLogin => null;
  @override
  bool get showTimestamps => false;
  @override
  String get timestampFormat => 'HH:mm';
  @override
  bool isMounted() => true;
  @override
  void markDirty() {}
  @override
  void mutate(void Function() fn) => fn();
  @override
  Future<void> closePanel() async {}
  @override
  void addSystemMessage(String channel, String text) {}
  @override
  int get maxMessages => 500;
  @override
  int get recentMessagesLimit => 100;
  @override
  bool get mentionPush => false;
  @override
  ValueNotifier<bool> atBottomNotifier(String channel) => ValueNotifier(true);
  @override
  void disposeChannelNotifiers(String channel) {}
  @override
  void forgetAtBottomNotifier(String channel) {}
  @override
  void forgetSearch(String channel) {}
  @override
  void invalidateCaches() {}
}

// Interface fakes for deps mergeHistory never touches. Calls throw so a new
// dependency call fails loudly instead of silently returning null.
mixin _Unimplemented {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$runtimeType.${invocation.memberName}');
}

class _FakeConn with _Unimplemented implements ChatConnectionManager {}

class _FakeEmotes with _Unimplemented implements EmoteManager {
  @override
  final EmoteStore store = EmoteStore();
}

class _FakeAnalytics with _Unimplemented implements AnalyticsService {}

class _FakePlayer with _Unimplemented implements StreamPlayerController {}

class _FakeNotifs with _Unimplemented implements NotificationService {}

class _FakeThreads with _Unimplemented implements ThreadPanels {}

class _FakeComposer with _Unimplemented implements ComposerController {}

ChannelManager _channelManager(Chat chat) {
  final session = Session();
  final userStore = UserStore();
  final pingManager = PingManager();
  final ignoreManager = IgnoreManager();
  final history = ChatHistoryController(
    chat: chat,
    session: session,
    recentMessages: RecentMessagesService(),
    ignoreManager: ignoreManager,
    pingManager: pingManager,
    userStore: userStore,
    emoteManager: _FakeEmotes(),
    badgeService: TwitchBadgeService(),
    maxMessages: () => 500,
    recentMessagesLimit: () => 100,
  );
  return ChannelManager(
    chat: chat,
    session: session,
    chatConn: _FakeConn(),
    irc: IrcService(),
    ircRead: IrcReadService(),
    twitchAuth: TwitchAuth(),
    emoteManager: _FakeEmotes(),
    badgeService: TwitchBadgeService(),
    analytics: _FakeAnalytics(),
    streamPlayer: _FakePlayer(),
    userStore: userStore,
    pingManager: pingManager,
    ignoreManager: ignoreManager,
    notificationService: _FakeNotifs(),
    threads: _FakeThreads(),
    composer: _FakeComposer(),
    broadcastWidgets: BroadcastWidgets(selectedChannel: () => null),
    tileCache: {},
    channelNotifier: ValueNotifier(const ['test']),
    selectedTabIndex: ValueNotifier(0),
    recentMessagesService: null,
    mentionsChannel: '@mentions',
    history: history,
    host: _ChannelManagerHost(),
  );
}

TwitchMessage _live(String id) => TwitchMessage(
  login: 'alice',
  text: 'hello $id',
  messageId: id,
  channel: 'test',
);

void main() {
  group('ChannelManager.history mergeHistory', () {
    const noticeText = 'This room is now in slow mode.';

    TwitchMessage historyNotice(int tsMs) => RecentMessagesService.parseIrcLine(
      '@msg-id=slow_on;rm-received-ts=$tsMs :tmi.twitch.tv NOTICE #test :$noticeText',
      channel: 'test',
    )!;

    int sysRows(Chat chat, String text) => chat
        .channelFor('test')!
        .messages
        .items
        .where((m) => m.isSystem && m.text == text)
        .length;

    Chat mergeChat() {
      final chat = Chat();
      chat.ensure('test');
      return chat;
    }

    test('refetch overlap with identical text and timestamp folds', () {
      final chat = mergeChat();
      addTearDown(chat.dispose);
      final manager = _channelManager(chat);
      const t0 = 1767225600000;
      manager.history.mergeHistory('test', [historyNotice(t0)]);
      manager.history.mergeHistory('test', [historyNotice(t0)]);
      expect(sysRows(chat, noticeText), 1);
    });

    test('live row plus refetch overlap folds', () {
      final chat = mergeChat();
      addTearDown(chat.dispose);
      final manager = _channelManager(chat);
      final t0 = DateTime.now();
      chat
          .channelFor('test')!
          .receive(
            TwitchMessage(
              login: '',
              text: noticeText,
              isSystem: true,
              channel: 'test',
              timestamp: t0,
            ),
            maxMessages: 500,
            isSelected: true,
            ownLogin: null,
          );
      manager.history.mergeHistory('test', [
        historyNotice(t0.millisecondsSinceEpoch),
      ]);
      expect(sysRows(chat, noticeText), 1);
    });
  });

  test('status text bumps only the status version, never tiles', () {
    final info = ChannelInfo();
    addTearDown(info.dispose);
    var structural = 0;
    var status = 0;
    info.version.addListener(() => structural++);
    info.statusVersion.addListener(() => status++);

    info.setStatus('Live with 10 viewers');
    expect(info.status, 'Live with 10 viewers');
    expect(structural, 0);
    expect(status, 1);

    // Same text is a no-op on both notifiers.
    info.setStatus('Live with 10 viewers');
    expect(structural, 0);
    expect(status, 1);

    // The 30s poll ticking viewer counts must not invalidate tiles.
    info.setStatus('Live with 11 viewers');
    expect(structural, 0);
    expect(status, 2);
  });

  test('structural writes still bump the tile-dropping version', () {
    final info = ChannelInfo();
    addTearDown(info.dispose);
    var structural = 0;
    var status = 0;
    info.version.addListener(() => structural++);
    info.statusVersion.addListener(() => status++);
    info.setBroadcasterId('123');
    info.setHistoryLoaded(true);
    info.touch();
    expect(structural, 3);
    expect(status, 0);

    // Guarded setters stay silent on identical values.
    info.setBroadcasterId('123');
    info.setHistoryLoaded(true);
    expect(structural, 3);
  });

  group('Channel.addSystemMessage', () {
    test('inserts the row and truncates to the cap', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      for (var i = 0; i < 4; i++) {
        channel.receive(
          _live('m$i'),
          maxMessages: 10,
          isSelected: true,
          ownLogin: null,
        );
      }
      expect(channel.messages.length, 4);

      expect(channel.addSystemMessage('Connected', maxMessages: 3), isTrue);

      expect(channel.messages.length, 3);
      expect(channel.messages.items.first.text, 'Connected');
      expect(channel.messages.items.first.isSystem, isTrue);
    });

    test('a duplicate id returns false and does not truncate', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      expect(
        channel.addSystemMessage('hello', messageId: 'dup', maxMessages: 10),
        isTrue,
      );
      for (var i = 0; i < 4; i++) {
        channel.receive(
          _live('m$i'),
          maxMessages: 10,
          isSelected: true,
          ownLogin: null,
        );
      }
      final before = channel.messages.length;

      expect(
        channel.addSystemMessage('hello', messageId: 'dup', maxMessages: 1),
        isFalse,
      );

      expect(channel.messages.length, before);
    });
  });
}
