import 'dart:async';

import 'package:ermchat/channels/channel_session.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/archive.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/chat_history_controller.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/emote_store.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/stream_player_controller.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/irc/transport/read.dart';
import 'package:ermchat/irc/transport/write.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/chat/channel/info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Interface fakes for deps mergeHistory never touches. Calls throw so a new
// dependency call fails loudly instead of silently returning null.
mixin _Unimplemented {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$runtimeType.${invocation.memberName}');
}

class _FakeConn with _Unimplemented implements ChatConnectionManager {
  final subscribed = <String>[];

  @override
  Future<void> subscribeChannel(String channel) async {
    subscribed.add(channel);
  }

  @override
  void maybeAddConnected(String channel) {}
}

class _FakeEmotes with _Unimplemented implements EmoteManager {
  @override
  final EmoteStore store = EmoteStore();

  @override
  void addPersonalSendersListener(void Function(Set<String>) listener) {}

  @override
  void removePersonalSendersListener(void Function(Set<String>) listener) {}

  @override
  Future<void> pruneStaleChannels(Set<String> channels) async {}
}

/// A network history that always answers empty, so a test can hold the
/// archive side without waiting on HTTP.
class _EmptyRecent extends RecentMessagesService {
  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
    DateTime? after,
  }) async => const [];

  @override
  Future<List<TwitchMessage>> fetchRecentPreferWarm(
    String channel, {
    int limit = 100,
  }) async => const [];
}

/// Records the restore order and lets the test hold the visible channel's
/// read open while the others are still waiting.
class _GatedHistory extends ChatHistoryController {
  _GatedHistory({
    required super.chat,
    required super.session,
    required super.recentMessages,
    required super.ignoreManager,
    required super.pingManager,
    required super.userStore,
    required super.emoteManager,
    required super.badgeService,
    required super.maxMessages,
    required super.recentMessagesLimit,
    super.archive,
  });

  final started = <String>[];
  final gates = <String, Completer<void>>{};

  @override
  Future<void> restoreOnce(String channel) {
    final gate = gates[channel];
    if (gate != null) return gate.future;
    started.add(channel);
    return (gates[channel] = Completer<void>()).future;
  }
}

class _FakeAnalytics with _Unimplemented implements AnalyticsService {}

class _FakePlayer with _Unimplemented implements StreamPlayerController {}

ChannelSession _channelSession(
  Chat chat, {
  ChatHistoryController? history,
  RecentMessagesService? recent,
  ChatConnectionManager? conn,
}) {
  final session = Session();
  final userStore = UserStore();
  String? selected = 'test';
  return ChannelSession(
    chat: chat,
    session: session,
    chatConn: conn ?? _FakeConn(),
    irc: IrcService(),
    ircRead: IrcReadService(),
    emoteManager: _FakeEmotes(),
    badgeService: TwitchBadgeService(),
    analytics: _FakeAnalytics(),
    streamPlayer: _FakePlayer(),
    userStore: userStore,
    history:
        history ??
        ChatHistoryController(
          chat: chat,
          session: session,
          recentMessages: recent ?? _EmptyRecent(),
          ignoreManager: IgnoreManager(),
          pingManager: PingManager(),
          userStore: UserStore(),
          emoteManager: _FakeEmotes(),
          badgeService: TwitchBadgeService(),
          maxMessages: () => 500,
          recentMessagesLimit: () => 100,
        ),
    recentMessagesService: recent,
    selectedChannel: () => selected,
    setSelectedChannel: (value) => selected = value,
    maxMessages: () => 500,
    recentMessagesLimit: () => 100,
  );
}

TwitchMessage _live(String id) => TwitchMessage(
  login: 'alice',
  text: 'hello $id',
  messageId: id,
  channel: 'test',
);

void main() {
  group('ChannelSession.loadChannels', () {
    ({ChannelSession session, _GatedHistory history, _FakeConn conn}) boot(
      Map<String, Object> prefs,
    ) {
      SharedPreferences.setMockInitialValues(prefs);
      final chat = Chat();
      addTearDown(chat.dispose);
      final conn = _FakeConn();
      final history = _GatedHistory(
        chat: chat,
        session: Session(),
        recentMessages: _EmptyRecent(),
        ignoreManager: IgnoreManager(),
        pingManager: PingManager(),
        userStore: UserStore(),
        emoteManager: _FakeEmotes(),
        badgeService: TwitchBadgeService(),
        maxMessages: () => 500,
        recentMessagesLimit: () => 100,
        archive: Archive(Future<ArchiveStore?>.value(null)),
      );
      final session = _channelSession(
        chat,
        history: history,
        recent: _EmptyRecent(),
        conn: conn,
      );
      return (session: session, history: history, conn: conn);
    }

    void drain(_GatedHistory history) {
      for (final gate in history.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
    }

    test('by default every channel joins and restores at launch', () async {
      final booted = boot({
        'channels': ['one', 'two', 'three'],
        'reopen_last_channel': true,
        'last_channel': 'two',
        'archive_enabled': false,
      });
      await booted.session.loadRecentMessagesConfig();
      await booted.session.loadChannels();
      expect(booted.conn.subscribed, ['one', 'two', 'three']);
      expect(booted.history.started, [
        'two',
      ], reason: 'the visible channel reads its archive first');

      booted.history.gates['two']!.complete();
      await pumpEventQueue();
      expect(booted.history.started, [
        'two',
        'one',
        'three',
      ], reason: 'a skipped gap fill leaves a hole in the archive');

      drain(booted.history);
      await pumpEventQueue();
    });

    test('lazy mode joins and restores a channel on first show', () async {
      final booted = boot({
        'channels': ['one', 'two', 'three'],
        'reopen_last_channel': true,
        'last_channel': 'two',
        'archive_enabled': false,
        'lazy_channels': true,
      });
      await booted.session.loadRecentMessagesConfig();
      await booted.session.loadChannels();
      expect(booted.conn.subscribed, ['two']);
      expect(booted.history.started, ['two']);

      booted.history.gates['two']!.complete();
      await pumpEventQueue();
      expect(booted.history.started, [
        'two',
      ], reason: 'unopened channels stay unjoined and unfetched');
      expect(booted.conn.subscribed, ['two']);

      booted.session.selectChannel('one');
      await pumpEventQueue();
      expect(booted.conn.subscribed, ['two', 'one']);
      expect(booted.history.started, ['two', 'one']);

      booted.session.selectChannel('one');
      await pumpEventQueue();
      expect(booted.history.started, [
        'two',
        'one',
      ], reason: 'a page restores once');

      // A split pane shows a channel without selecting it.
      booted.session.ensureBackfill('three');
      booted.session.ensureBackfill('three');
      await pumpEventQueue();
      expect(booted.conn.subscribed, ['two', 'one', 'three']);
      expect(booted.history.started, ['two', 'one', 'three']);

      drain(booted.history);
      await pumpEventQueue();
    });

    test('lazy mode is inert while the archive is on', () async {
      final booted = boot({
        'channels': ['one', 'two', 'three'],
        'reopen_last_channel': true,
        'last_channel': 'two',
        'archive_enabled': true,
        'lazy_channels': true,
      });
      await booted.session.loadRecentMessagesConfig();
      await booted.session.loadChannels();
      expect(booted.conn.subscribed, ['one', 'two', 'three']);

      booted.history.gates['two']!.complete();
      await pumpEventQueue();
      expect(booted.history.started, ['two', 'one', 'three']);

      drain(booted.history);
      await pumpEventQueue();
    });
  });

  group('ChannelSession.history mergeHistory', () {
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

    test('refetch and live overlaps fold into one row', () {
      final chat = mergeChat();
      addTearDown(chat.dispose);
      final session = _channelSession(chat);
      const t0 = 1767225600000;
      session.history.mergeHistory('test', [historyNotice(t0)]);
      session.history.mergeHistory('test', [historyNotice(t0)]);
      expect(sysRows(chat, noticeText), 1);

      final now = DateTime.now();
      chat
          .channelFor('test')!
          .receive(
            TwitchMessage(
              login: '',
              text: 'Live only notice.',
              isSystem: true,
              channel: 'test',
              timestamp: now,
            ),
            maxMessages: 500,
            isSelected: true,
            ownLogin: null,
          );
      session.history.mergeHistory('test', [
        RecentMessagesService.parseIrcLine(
          '@msg-id=x;rm-received-ts=${now.millisecondsSinceEpoch} :tmi.twitch.tv NOTICE #test :Live only notice.',
          channel: 'test',
        )!,
      ]);
      expect(sysRows(chat, 'Live only notice.'), 1);
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

  test('structural writes bump the tile-dropping version', () {
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
