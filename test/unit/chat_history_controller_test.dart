import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/chat_history_controller.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/ignore_manager.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:flutter_test/flutter_test.dart';

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

ChatHistoryController _controller(Chat chat, EmoteManager emotes) =>
    ChatHistoryController(
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

  test('a full channel commit heals history baked before the catalog', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    controller.mergeHistory('ch', [historyRow('h1', 'Alpha')]);
    final row = chat.channelFor('ch')!.messages.byId('h1')!;
    expect(row.emoteTokens, isEmpty);

    emotes.store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [sevenTv('a', 'Alpha')]),
      const [],
    );

    expect(row.emoteTokens!.map((t) => t.emote!.code).toList(), ['Alpha']);
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

  test('a full commit leaves live rows frozen', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    chat.ensure('ch');
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    controller.mergeHistory('ch', [historyRow('h1', 'Alpha')]);
    final live = TwitchMessage(
      login: 'bob',
      text: 'Alpha',
      messageId: 'live',
      channel: 'ch',
    )..emoteTokens = const [];
    chat.receive(
      'ch',
      live,
      maxMessages: 500,
      isSelected: true,
      ownLogin: null,
    );

    emotes.store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [sevenTv('a', 'Alpha')]),
      const [],
    );

    expect(
      chat.channelFor('ch')!.messages.byId('h1')!.emoteTokens,
      hasLength(1),
    );
    expect(chat.channelFor('ch')!.messages.byId('live')!.emoteTokens, isEmpty);
  });

  test('restamp on a missing channel is a no-op', () {
    final chat = Chat();
    addTearDown(chat.dispose);
    final emotes = EmoteManager();
    addTearDown(emotes.dispose);
    final controller = _controller(chat, emotes);
    addTearDown(controller.dispose);

    expect(controller.restampChannelEmotes('gone'), 0);
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
