import 'dart:async';

import 'package:ermchat/channels/channel_session.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/emotes/emote.dart';
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
import 'package:fake_async/fake_async.dart';
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
  List<EmoteToken>? parseMessageEmotes(
    TwitchMessage msg, {
    required String lookupChannel,
  }) => const [];

  @override
  bool catalogComplete(String channel) => false;

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

class _RowsRecent extends RecentMessagesService {
  _RowsRecent(this.newest, this.gap);

  final List<TwitchMessage> newest;
  final List<TwitchMessage> gap;
  final limits = <int>[];

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
    DateTime? after,
  }) async {
    limits.add(limit);
    if (limit >= 800) return gap;
    return newest;
  }

  @override
  Future<List<TwitchMessage>> fetchRecentPreferWarm(
    String channel, {
    int limit = 100,
  }) => fetchRecent(channel, limit: limit);
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
    this.restoreRows = const {},
  });

  final started = <String>[];
  final gates = <String, Completer<void>>{};
  final _runs = <String, Future<void>>{};
  final Map<String, List<TwitchMessage>> restoreRows;

  @override
  Future<void> restoreOnce(String channel) {
    final running = _runs[channel];
    if (running != null) return running;
    started.add(channel);
    final entered = gates[channel] = Completer<void>();
    final run = entered.future.then((_) {
      for (final row in restoreRows[channel] ?? const <TwitchMessage>[]) {
        mergeHistory(channel, [row]);
      }
    });
    _runs[channel] = run;
    return run.whenComplete(() => _runs.remove(channel));
  }
}

class _FakeAnalytics with _Unimplemented implements AnalyticsService {}

class _FakePlayer with _Unimplemented implements StreamPlayerController {}

ChannelSession _channelSession(
  Chat chat, {
  ChatHistoryController? history,
  RecentMessagesService? recent,
  ChatConnectionManager? conn,
  Duration archiveGrace = const Duration(seconds: 4),
  Duration startupBackfillStagger = Duration.zero,
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
    archiveGrace: archiveGrace,
    startupBackfillStagger: startupBackfillStagger,
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
      Map<String, Object> prefs, {
      Duration archiveGrace = const Duration(seconds: 4),
      Duration startupBackfillStagger = Duration.zero,
      RecentMessagesService? recent,
      Map<String, List<TwitchMessage>> restoreRows = const {},
    }) {
      SharedPreferences.setMockInitialValues(prefs);
      final chat = Chat();
      addTearDown(chat.dispose);
      final conn = _FakeConn();
      final service = recent ?? _EmptyRecent();
      final history = _GatedHistory(
        chat: chat,
        session: Session(),
        recentMessages: service,
        ignoreManager: IgnoreManager(),
        pingManager: PingManager(),
        userStore: UserStore(),
        emoteManager: _FakeEmotes(),
        badgeService: TwitchBadgeService(),
        maxMessages: () => 500,
        recentMessagesLimit: () => 100,
        archive: Archive(Future<ArchiveStore?>.value(null)),
        restoreRows: restoreRows,
      );
      final session = _channelSession(
        chat,
        history: history,
        recent: service,
        conn: conn,
        archiveGrace: archiveGrace,
        startupBackfillStagger: startupBackfillStagger,
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

    test('saved backfills start in a staggered pair', () {
      fakeAsync((async) {
        const stagger = Duration(milliseconds: 250);
        final booted = boot({
          'channels': ['launch', 'one', 'two', 'three', 'four', 'five', 'six'],
          'reopen_last_channel': true,
          'last_channel': 'launch',
          'archive_enabled': false,
        }, startupBackfillStagger: stagger);
        unawaited(
          booted.session.loadRecentMessagesConfig().then(
            (_) => booted.session.loadChannels(),
          ),
        );
        async.flushMicrotasks();
        expect(booted.history.started, [
          'launch',
        ], reason: 'the launch channel starts before the saved-channel queue');

        booted.history.gates['launch']!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 249));
        expect(booted.history.started, ['launch']);

        async.elapse(const Duration(milliseconds: 1));
        expect(booted.history.started, ['launch', 'one']);
        async.elapse(stagger - const Duration(milliseconds: 1));
        expect(booted.history.started, ['launch', 'one']);
        async.elapse(const Duration(milliseconds: 1));
        expect(booted.history.started, ['launch', 'one', 'two']);

        async.elapse(const Duration(seconds: 1));
        expect(
          booted.history.started,
          ['launch', 'one', 'two'],
          reason: 'held restores must not let more than two backfills overlap',
        );

        booted.history.gates['one']!.complete();
        async.flushMicrotasks();
        expect(booted.history.started, ['launch', 'one', 'two', 'three']);
        booted.history.gates['two']!.complete();
        async.flushMicrotasks();
        expect(booted.history.started, [
          'launch',
          'one',
          'two',
          'three',
          'four',
        ]);

        drain(booted.history);
        async.flushMicrotasks();
        async.elapse(stagger);
        drain(booted.history);
        async.flushMicrotasks();
        expect(booted.history.started, [
          'launch',
          'one',
          'two',
          'three',
          'four',
          'five',
          'six',
        ]);
        booted.session.dispose();
      });
    });

    test('dispose drops queued startup backfills', () {
      fakeAsync((async) {
        final booted = boot({
          'channels': ['launch', 'one', 'two'],
          'reopen_last_channel': true,
          'last_channel': 'launch',
          'archive_enabled': false,
        }, startupBackfillStagger: const Duration(milliseconds: 250));
        unawaited(
          booted.session.loadRecentMessagesConfig().then(
            (_) => booted.session.loadChannels(),
          ),
        );
        async.flushMicrotasks();
        booted.history.gates['launch']!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));
        expect(booted.history.started, ['launch', 'one']);

        booted.session.dispose();
        drain(booted.history);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(booted.history.started, [
          'launch',
          'one',
        ], reason: 'disposed sessions never start pending saved-channel reads');
      });
    });

    test('a stalled archive restore does not hold the rows', () async {
      final booted = boot({
        'channels': ['one'],
        'reopen_last_channel': true,
        'last_channel': 'one',
        'archive_enabled': true,
      }, archiveGrace: const Duration(milliseconds: 20));
      await booted.session.loadRecentMessagesConfig();
      await booted.session.loadChannels();
      expect(booted.history.started, ['one']);

      // The restore gate stays open; the network answered empty.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        booted.session.chat.channelFor('one')!.info.historyLoaded,
        isTrue,
        reason: 'a stuck archive open must not hold the backfill',
      );

      booted.history.gates['one']!.complete();
      await pumpEventQueue();
    });

    test('a late archive restore still fills the network gap', () async {
      final lastSeen = DateTime.utc(2026, 10, 19, 12);
      TwitchMessage row(int second) => TwitchMessage(
        login: 'alice',
        text: 's$second',
        messageId: 'r$second',
        channel: 'one',
        timestamp: lastSeen.add(Duration(seconds: second)),
      );
      final recent = _RowsRecent(
        [for (var s = 200; s < 300; s++) row(s)],
        [row(100), row(0)],
      );
      final booted = boot(
        {
          'channels': ['one'],
          'reopen_last_channel': true,
          'last_channel': 'one',
          'archive_enabled': true,
          'history_gap_fill': 1,
        },
        archiveGrace: const Duration(milliseconds: 20),
        recent: recent,
        restoreRows: {
          'one': [row(0)],
        },
      );
      await booted.session.loadRecentMessagesConfig();
      await booted.session.loadChannels();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        booted.session.chat.channelFor('one')!.info.historyLoaded,
        isTrue,
        reason: 'network rows show before the slow restore',
      );
      expect(recent.limits, [100]);
      booted.history.gates['one']!.complete();
      await pumpEventQueue();

      expect(
        booted.session.chat.channelFor('one')!.messages.byId('r0'),
        isNotNull,
        reason: 'the held restore finished',
      );
      expect(recent.limits, [100, 800]);
      expect(
        booted.session.chat.channelFor('one')!.messages.byId('r100'),
        isNotNull,
        reason: 'the late restore must not skip gap recovery',
      );
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
