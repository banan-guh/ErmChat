import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/widgets/chat_view.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _msg(int i) => TwitchMessage(
  login: 'user$i',
  text: 'message $i',
  channel: 'test',
  messageId: 'msg-$i',
  userId: 'u$i',
);

void main() {
  testWidgets('tile cache returns the same widget across list rebuilds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final em = EmoteManager();
    final builder = MessageBuilder(
      emoteSource: em,
      badgeService: TwitchBadgeService(),
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final messages = [for (var i = 20; i > 0; i--) _msg(i)];
    final messageNotifier = ValueNotifier(0);
    final atBottom = ValueNotifier(true);
    final controller = ScrollController();
    final tileCache = <String, Map<String?, Widget>>{};
    addTearDown(em.dispose);
    addTearDown(controller.dispose);
    addTearDown(messageNotifier.dispose);
    addTearDown(atBottom.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatView(
            channel: 'test',
            messages: messages,
            tileCache: tileCache,
            atBottomNotifier: atBottom,
            messageNotifier: messageNotifier,
            scrollController: controller,
            messageBuilder: builder,
            onShowUserProfile: (_, _, {displayName}) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final cache = tileCache['test'];
    expect(cache, isNotNull, reason: 'main chat must populate the cache');
    expect(cache, isNotEmpty);
    final first = cache!['msg-20'];
    expect(first, isNotNull, reason: 'newest row should be cached');

    // A rebuild with the same message set must reuse the cached widget.
    messageNotifier.value++;
    await tester.pump();
    expect(
      identical(tileCache['test']!['msg-20'], first),
      isTrue,
      reason: 'cache hit must not replace the cached tile',
    );

    // Every visible row that is still in the buffer should stay cached.
    final cachedIds = tileCache['test']!.keys.whereType<String>().toSet();
    expect(cachedIds, contains('msg-20'));
    expect(cachedIds, contains('msg-1'));
  });

  testWidgets('LRU window keeps the newest row cached past the cap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final em = EmoteManager();
    final builder = MessageBuilder(
      emoteSource: em,
      badgeService: TwitchBadgeService(),
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final messages = <TwitchMessage>[for (var i = 20; i > 0; i--) _msg(i)];
    final messageNotifier = ValueNotifier(0);
    final atBottom = ValueNotifier(true);
    final controller = ScrollController();
    final tileCache = <String, Map<String?, Widget>>{};
    addTearDown(em.dispose);
    addTearDown(controller.dispose);
    addTearDown(messageNotifier.dispose);
    addTearDown(atBottom.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatView(
            channel: 'big',
            messages: messages,
            tileCache: tileCache,
            atBottomNotifier: atBottom,
            messageNotifier: messageNotifier,
            scrollController: controller,
            messageBuilder: builder,
            onShowUserProfile: (_, _, {displayName}) {},
          ),
        ),
      ),
    );
    await tester.pump();

    // Churn past the 300 cap: each new message is a fresh row, so the window
    // reaches its bound and starts evicting. The on-screen newest row must
    // survive; the old policy evicted exactly that row.
    for (var n = 0; n < 340; n++) {
      messages.insert(0, _msg(1000 + n));
      messageNotifier.value++;
      await tester.pump();
    }

    final cache = tileCache['big']!;
    expect(cache.length, lessThanOrEqualTo(300));
    const newestId = 'msg-1339';
    expect(
      cache.containsKey(newestId),
      isTrue,
      reason: 'the visible newest row must not be evicted',
    );
    final newest = cache[newestId];
    messageNotifier.value++;
    await tester.pump();
    expect(
      identical(tileCache['big']![newestId], newest),
      isTrue,
      reason: 'the newest row should hit, not be rebuilt',
    );
  });

  testWidgets('a non-kept-alive page restores its scroll offset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final em = EmoteManager();
    final builder = MessageBuilder(
      emoteSource: em,
      badgeService: TwitchBadgeService(),
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final messages = [for (var i = 60; i > 0; i--) _msg(i)];
    final messageNotifier = ValueNotifier(0);
    final atBottom = ValueNotifier(true);
    final controller = ScrollController();
    final tileCache = <String, Map<String?, Widget>>{};
    // Toggles the page in and out of the same route, like the channel pager.
    final shown = ValueNotifier(true);
    addTearDown(em.dispose);
    addTearDown(controller.dispose);
    addTearDown(messageNotifier.dispose);
    addTearDown(atBottom.dispose);
    addTearDown(shown.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, visible, _) => visible
                ? ChatView(
                    channel: 'restore',
                    messages: messages,
                    tileCache: tileCache,
                    atBottomNotifier: atBottom,
                    messageNotifier: messageNotifier,
                    scrollController: controller,
                    messageBuilder: builder,
                    keepAlive: false,
                    onShowUserProfile: (_, _, {displayName}) {},
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ChatView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final before = controller.offset;
    expect(before, greaterThan(0));

    shown.value = false;
    await tester.pumpAndSettle();
    shown.value = true;
    await tester.pumpAndSettle();

    expect(controller.offset, before);
  });
}
