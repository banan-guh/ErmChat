import 'package:ermchat/channels/channel_manager.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/composer/composer_controller.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/threads.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/emote_manager.dart';
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

class _FakeEmotes with _Unimplemented implements EmoteManager {}

class _FakeAnalytics with _Unimplemented implements AnalyticsService {}

class _FakePlayer with _Unimplemented implements StreamPlayerController {}

class _FakeNotifs with _Unimplemented implements NotificationService {}

class _FakeThreads with _Unimplemented implements ThreadPanels {}

class _FakeComposer with _Unimplemented implements ComposerController {}

ChannelManager _channelManager(Chat chat) => ChannelManager(
  chat: chat,
  session: Session(),
  chatConn: _FakeConn(),
  irc: IrcService(),
  ircRead: IrcReadService(),
  twitchAuth: TwitchAuth(),
  emoteManager: _FakeEmotes(),
  badgeService: TwitchBadgeService(),
  analytics: _FakeAnalytics(),
  streamPlayer: _FakePlayer(),
  userStore: UserStore(),
  pingManager: PingManager(),
  ignoreManager: IgnoreManager(),
  notificationService: _FakeNotifs(),
  threads: _FakeThreads(),
  composer: _FakeComposer(),
  broadcastWidgets: BroadcastWidgets(selectedChannel: () => null),
  tileCache: {},
  channelNotifier: ValueNotifier(const ['test']),
  selectedTabIndex: ValueNotifier(0),
  recentMessagesService: null,
  mentionsChannel: '@mentions',
  host: _ChannelManagerHost(),
);

void main() {
  group('ChannelManager.mergeHistory', () {
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
      manager.mergeHistory('test', [historyNotice(t0)]);
      manager.mergeHistory('test', [historyNotice(t0)]);
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
      manager.mergeHistory('test', [historyNotice(t0.millisecondsSinceEpoch)]);
      expect(sysRows(chat, noticeText), 1);
    });
  });
}
