import 'dart:io';

import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/chat/channel/messages.dart';
import 'package:ermchat/services/archive.dart';
import 'package:ermchat/services/archive_store.dart';
import 'package:ermchat/services/chat_history_controller.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:ermchat/util/signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Emote sevenTv(String id, String code) => Emote(
  id: id,
  code: code,
  meta: const SevenTvMeta(),
  scales: {EmoteScale.medium: 'https://example.com/$id.png'},
  scope: EmoteScope.channel,
);

TwitchMessage historyRow(String id, String text) => TwitchMessage(
  login: 'alice',
  text: text,
  messageId: id,
  channel: 'ch',
  isHistory: true,
);

ChatHistoryController _controller(
  Chat chat,
  EmoteManager emotes, {
  ChatSignal<bool>? emoteReloading,
  Archive? archive,
  RecentMessagesService? recent,
  DateTime Function()? now,
}) => ChatHistoryController(
  chat: chat,
  session: Session(),
  recentMessages: recent ?? RecentMessagesService(),
  ignoreManager: IgnoreManager(),
  pingManager: PingManager(),
  userStore: UserStore(),
  emoteManager: emotes,
  badgeService: TwitchBadgeService(),
  maxMessages: () => 500,
  recentMessagesLimit: () => 100,
  emoteReloading: emoteReloading,
  archive: archive,
  now: now,
);

void main() {
  test('mergeHistory does not resurrect a removed channel', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('test');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    chat.remove('test');
    controller.mergeHistory('test', [
      TwitchMessage(login: 'a', text: 'hi', messageId: 'm1', channel: 'test'),
    ]);

    expect(chat.contains('test'), isFalse);
    expect(chat.names, isEmpty);
    expect(chat.mentions.isEmpty, isTrue);
  });

  test('a live 7TV delta does not heal history', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    controller.mergeHistory('ch', [historyRow('h1', 'Alpha')]);
    final row = chat.channelFor('ch')!.messages.byId('h1')!;

    emotes.updateSevenTvEmotes('ch', added: [sevenTv('a', 'Alpha')]);

    expect(row.emoteTokens, isEmpty);
  });

  test('a full commit heals partial rows and leaves complete rows frozen', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    controller.mergeHistory('ch', [historyRow('h1', 'Alpha')]);
    expect(chat.channelFor('ch')!.messages.byId('h1')!.emoteTokens, isEmpty);
    final live = TwitchMessage(
      login: 'bob',
      text: 'Alpha',
      messageId: 'live',
      channel: 'ch',
    )..emoteTokens = const [];
    // Baked live before the channel set landed (the bug: never healed).
    final early =
        TwitchMessage(
            login: 'carol',
            text: 'Alpha',
            messageId: 'early',
            channel: 'ch',
          )
          ..emoteTokens = const []
          ..emotesPartial = true;
    for (final m in [live, early]) {
      chat.receive('ch', m, maxMessages: 500, isSelected: true, ownLogin: null);
    }

    emotes.store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [sevenTv('a', 'Alpha')]),
      const [],
    );

    final healed = chat.channelFor('ch')!.messages.byId('h1')!.emoteTokens!;
    expect(healed.map((t) => t.emote!.code).toList(), ['Alpha']);
    expect(chat.channelFor('ch')!.messages.byId('live')!.emoteTokens, isEmpty);
    expect(early.emoteTokens!.map((t) => t.emote!.code).toList(), ['Alpha']);
  });

  // Rows baked "complete" while a provider was failing stayed bare after
  // Reload emotes until a restart.
  test('a manual reload heals rows baked complete', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final reloading = ChatSignal<bool>();
    final controller = _controller(chat, emotes, emoteReloading: reloading);
    addTearDown(controller.dispose);
    final baked = TwitchMessage(
      login: 'bob',
      text: 'Alpha',
      messageId: 'baked',
      channel: 'ch',
    )..emoteTokens = const [];
    chat.receive(
      'ch',
      baked,
      maxMessages: 500,
      isSelected: true,
      ownLogin: null,
    );

    reloading.emit(true);
    emotes.store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [sevenTv('a', 'Alpha')]),
      const [],
    );
    expect(baked.emoteTokens!.map((t) => t.emote!.code).toList(), [
      'Alpha',
    ], reason: 'each catalog landing mid-reload heals every row');
    reloading.emit(false);
  });

  test('a personal set landing after its message heals that message', () async {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    // The message that triggers the sender's 7TV presence lands first.
    TwitchMessage row(String id, String userId) => TwitchMessage(
      login: userId,
      userId: userId,
      text: 'hi Mine',
      messageId: id,
      channel: 'ch',
    )..emoteTokens = const [];
    final sender = row('m1', 'u1');
    final other = row('m2', 'u2');
    for (final m in [sender, other]) {
      chat.receive('ch', m, maxMessages: 500, isSelected: true, ownLogin: null);
    }

    // Socket order: set created, filled, then granted to the sender.
    emotes.trackForeignPersonalSet('set');
    emotes.applyForeignPersonalSetUpdate(
      setId: 'set',
      added: [sevenTv('p1', 'Mine')],
      removedIds: const [],
      renamed: const {},
    );
    await emotes.trackForeignPersonalGrant(['u1'], 'set');

    expect(sender.emoteTokens!.map((t) => t.emote!.code), ['Mine']);
    expect(
      other.emoteTokens,
      isEmpty,
      reason: 'personal emotes are sender-scoped',
    );
  });

  test('a reconnect gap reaches the archive and survives a cold start', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('gap');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/archive.db';
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    TwitchMessage row(int minute) => TwitchMessage(
      login: 'alice',
      text: 'm$minute',
      messageId:
          '0000${minute.toString().padLeft(4, '0')}-0b7d-4c55-9a10-6d2e8f4b7a01',
      channel: 'ch',
      userId: '42',
      timestamp: DateTime.utc(2026, 10, 15, 12, minute),
    );
    List<TwitchMessage> rows(int from, int to) => [
      for (var i = from; i < to; i++) row(i),
    ];
    List<TwitchMessage> gaps(Chat chat) => [
      for (final m in chat.channelFor('ch')!.messages.items)
        if (m.messageId?.startsWith(Messages.historyGapIdPrefix) ?? false) m,
    ];

    // Session one: chat, then a reconnect whose fetch cannot reach back.
    var store = await ArchiveStore.open(path, factory: databaseFactoryFfi);
    var archive = Archive(Future.value(store));
    var chat = Chat();
    chat.ensure('ch');
    var controller = _controller(chat, emotes, archive: archive);
    controller.mergeHistory('ch', rows(0, 5));
    controller.mergeHistory('ch', rows(30, 35));
    final note = gaps(chat).single;
    await archive.writer.flush();
    controller.dispose();
    chat.dispose();
    await store.close();

    // Session two: the buffer comes back from disk with the note in place.
    store = await ArchiveStore.open(path, factory: databaseFactoryFfi);
    archive = Archive(Future.value(store));
    chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    controller = _controller(chat, emotes, archive: archive);
    addTearDown(controller.dispose);
    await controller.restoreFromArchive('ch');
    final restored = gaps(chat);
    expect(restored, hasLength(1), reason: 'the gap note was not archived');
    expect(restored.single.timestamp, note.timestamp);
    expect(restored.single.isSystem, isTrue);
    final items = chat.channelFor('ch')!.messages.items;
    final at = items.indexOf(restored.single);
    expect(
      (items[at + 1].text, items[at - 1].text),
      ('m4', 'm30'),
      reason: 'the note must sit between the rows it separates',
    );
    // The same network rows again: still one note.
    controller.mergeHistory('ch', rows(30, 35));
    expect(gaps(chat), hasLength(1));
    await store.close();
  });

  test('gap fill reaches back only when the gap likely fits', () async {
    final lastSeen = DateTime.utc(2026, 10, 19, 12);
    TwitchMessage row(int second) => TwitchMessage(
      login: 'alice',
      text: 's$second',
      messageId: 'r$second',
      channel: 'ch',
      timestamp: lastSeen.add(Duration(seconds: second)),
    );
    // (dynamic fetch on, first fetched second, reaches back?): rows run one
    // a second up to [start] + 100, so [start] seconds of the gap are missing.
    final cases = [(false, 200, false), (true, 200, true), (true, 600, false)];
    for (final (on, start, reaches) in cases) {
      SharedPreferences.setMockInitialValues({'history_gap_fill': on ? 1 : 0});
      final chat = Chat()..ensure('ch');
      final emotes = EmoteManager();
      final afters = <DateTime?>[];
      final recent = _RecordingRecentMessages(afters, [
        for (var s = 0; s <= start + 100; s++) row(s),
      ]);
      final controller = _controller(chat, emotes, recent: recent);
      controller.mergeHistory('ch', [row(0)]);

      final newest = [for (var s = start; s < start + 100; s++) row(s)];
      final got = await controller.fillGap('ch', newest);
      expect(
        got.any((m) => m.messageId == 'r0'),
        reaches,
        reason: '${on ? 'on' : 'off'} missing $start seconds',
      );
      if (reaches) {
        expect(afters.single!.isBefore(lastSeen), isTrue);
        controller.mergeHistory('ch', got);
        expect(
          chat
              .channelFor('ch')!
              .messages
              .items
              .where(
                (m) =>
                    m.messageId?.startsWith(Messages.historyGapIdPrefix) ??
                    false,
              ),
          isEmpty,
          reason: 'a filled gap leaves no note',
        );
      } else {
        expect(afters, isEmpty);
      }
      controller.dispose();
      emotes.dispose();
      chat.dispose();
    }
  });

  test('a bridged gap note stays gone after a cold start', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('bridge');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/archive.db';
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    TwitchMessage row(int minute) => TwitchMessage(
      login: 'alice',
      text: 'm$minute',
      messageId:
          '0000${minute.toString().padLeft(4, '0')}-0b7d-4c55-9a10-6d2e8f4b7a01',
      channel: 'ch',
      userId: '42',
      timestamp: DateTime.utc(2026, 10, 15, 12, minute),
    );
    List<TwitchMessage> rows(int from, int to) => [
      for (var i = from; i < to; i++) row(i),
    ];
    List<TwitchMessage> gaps(Chat chat) => [
      for (final m in chat.channelFor('ch')!.messages.items)
        if (m.messageId?.startsWith(Messages.historyGapIdPrefix) ?? false) m,
    ];

    // Session one: note a gap and seal it, so the bridge edits a block.
    var store = await ArchiveStore.open(path, factory: databaseFactoryFfi);
    var archive = Archive(Future.value(store));
    var chat = Chat();
    chat.ensure('ch');
    var controller = _controller(chat, emotes, archive: archive);
    controller.mergeHistory('ch', rows(0, 5));
    controller.mergeHistory('ch', rows(30, 35));
    expect(gaps(chat), hasLength(1));
    await archive.writer.flush();
    // A later fetch reaching row 2 bridges the gap and drops the note.
    controller.mergeHistory('ch', rows(2, 40));
    expect(gaps(chat), isEmpty, reason: 'the bridge drops the note');
    await archive.writer.flush();
    controller.dispose();
    chat.dispose();
    await store.close();

    // Session two: a cold start must not restore the bridged note.
    store = await ArchiveStore.open(path, factory: databaseFactoryFfi);
    archive = Archive(Future.value(store));
    chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    controller = _controller(chat, emotes, archive: archive);
    addTearDown(controller.dispose);
    await controller.restoreFromArchive('ch');
    expect(gaps(chat), isEmpty, reason: 'the bridged gap note came back');
    await store.close();
  });

  test('a failing refetch notes its gap once and archives it', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('gapfail');
    addTearDown(() => dir.delete(recursive: true));
    final store = await ArchiveStore.open(
      '${dir.path}/archive.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(store.close);
    final archive = Archive(Future.value(store));
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final chat = Chat();
    addTearDown(chat.dispose);
    final channel = chat.ensure('ch');
    var clockNow = DateTime.utc(2026, 10, 15, 12, 10);
    final controller = _controller(
      chat,
      emotes,
      archive: archive,
      now: () => clockNow,
      // Every provider is down.
      recent: RecentMessagesService(
        client: MockClient((_) async => http.Response('down', 503)),
      ),
    );
    addTearDown(controller.dispose);
    controller.mergeHistory('ch', [
      for (var i = 0; i < 3; i++)
        TwitchMessage(
          login: 'alice',
          text: 'm$i',
          messageId: '0000000$i-0b7d-4c55-9a10-6d2e8f4b7a01',
          channel: 'ch',
          userId: '42',
          timestamp: DateTime.utc(2026, 10, 15, 12, i),
        ),
    ]);
    channel.setHistoryLoaded(true);

    // A flapping connection: three reconnects fail with no chat between.
    for (var k = 0; k < 3; k++) {
      await controller.refetchHistory('ch');
      clockNow = clockNow.add(const Duration(minutes: 1));
    }
    bool isGap(TwitchMessage m) =>
        m.messageId?.startsWith(Messages.historyGapIdPrefix) ?? false;
    final notes = channel.messages.items.where(isGap).toList();
    expect(notes, hasLength(1), reason: 'one place, one note');
    expect(notes.single.timestamp, DateTime.utc(2026, 10, 15, 12, 10));
    await archive.writer.flush();
    final stored = await archive.reader.newestRows('ch', 100);
    expect(
      stored.where(isGap),
      hasLength(1),
      reason: 'history must still show the gap after the buffer trims it',
    );
  });

  test('a cold start keeps the emotes rows were archived with', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('tokens');
    addTearDown(() => dir.delete(recursive: true));
    final store = await ArchiveStore.open(
      '${dir.path}/archive.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(store.close);
    final archive = Archive(Future.value(store));
    archive.writer.add(
      'ch',
      TwitchMessage(
          login: 'alice',
          text: 'catJAM',
          messageId: '00000001-0b7d-4c55-9a10-6d2e8f4b7a01',
          channel: 'ch',
          userId: '42',
          timestamp: DateTime.utc(2026, 10, 15, 12),
        )
        ..emoteTokens = [
          EmoteToken(
            emote: sevenTv('01F6', 'catJAM'),
            text: 'catJAM',
            start: 0,
            end: 6,
          ),
        ],
    );
    await archive.writer.flush();
    // The app starts with no catalog yet: a fresh parse would find nothing.
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final controller = _controller(chat, emotes, archive: archive);
    addTearDown(controller.dispose);
    await controller.restoreFromArchive('ch');
    final row = chat.channelFor('ch')!.messages.items.single;
    expect(row.emoteTokens?.map((t) => t.emote?.id), [
      '01F6',
    ], reason: 'the restore re-parsed over the stored emotes');
  });

  test('dispose detaches the catalog listener', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);

    controller.mergeHistory('ch', [historyRow('h1', 'Alpha')]);
    controller.dispose();

    emotes.store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [sevenTv('a', 'Alpha')]),
      const [],
    );

    expect(chat.channelFor('ch')!.messages.byId('h1')!.emoteTokens, isEmpty);
  });
}

/// Serves [rows] received after the requested time, newest [limit] of them,
/// and records each `after`.
class _RecordingRecentMessages extends RecentMessagesService {
  _RecordingRecentMessages(this.afters, this.rows);

  final List<DateTime?> afters;
  final List<TwitchMessage> rows;

  @override
  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
    DateTime? after,
  }) async {
    afters.add(after);
    final kept = [
      for (final m in rows)
        if (after == null || m.timestamp.isAfter(after)) m,
    ];
    return kept.length <= limit ? kept : kept.sublist(kept.length - limit);
  }
}
