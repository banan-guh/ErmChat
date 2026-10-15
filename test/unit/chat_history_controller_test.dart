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
}) => ChatHistoryController(
  chat: chat,
  session: Session(),
  recentMessages: RecentMessagesService(),
  ignoreManager: IgnoreManager(),
  pingManager: PingManager(),
  userStore: UserStore(),
  emoteManager: emotes,
  badgeService: TwitchBadgeService(),
  maxMessages: () => 500,
  recentMessagesLimit: () => 100,
  emoteReloading: emoteReloading,
  archive: archive,
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
