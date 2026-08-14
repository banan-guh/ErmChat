import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/widgets/message_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MessageBuilder makeBuilder(EmoteManager em) => MessageBuilder(
    emoteManager: em,
    badgeService: TwitchBadgeService(),
    onShowEmoteSheet: (_) {},
  );

  TwitchMessage makeMsg() => TwitchMessage(
    login: 'user',
    text: 'Pog',
    channel: 'test',
    messageId: 'm1',
  );

  test('cached spans are reused while the emote version is unchanged', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);

    expect(msg.cachedSpans, isNotNull);
    expect(msg.cachedSpansVersion, em.version);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    final again = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(again, spans), isTrue);
  });

  test('cached spans stay frozen across a live 7TV delta', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A live 7TV delta does not bump the version: already-rendered messages
    // keep the emote state they were built with (no retroactive re-render on
    // add/remove).
    em.updateSevenTvEmotes(
      'test',
      added: [
        const GenericEmote(
          id: 'e1',
          code: 'Pog',
          type: EmoteType.sevenTv,
          url: 'https://example.com/pog.png',
        ),
      ],
    );
    expect(em.version, msg.cachedSpansVersion);

    final again = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(again, spans), isTrue);
  });

  test('cached spans recompute after a full refetch notify', () async {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A non-delta notify (full refetch) bumps the version and the next build
    // lazily recomputes against the fresh emote data.
    await em.storeUserTwitchEmotes({});
    expect(em.version, greaterThan(msg.cachedSpansVersion!));

    makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(msg.cachedSpansVersion, em.version);
  });
}
