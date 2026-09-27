import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/widgets/chat_view.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Variable-height rows so a mis-ordered child list shows up during layout.
TwitchMessage _msg(int i) => TwitchMessage(
  login: 'user$i',
  text: (i % 3 == 0)
      ? 'message number $i with a body long enough to wrap across more than '
            'one line in a narrow phone viewport so row heights vary'
      : 'message number $i',
  channel: 'test',
  messageId: 'msg-$i',
  userId: 'u$i',
);

class _Harness {
  _Harness({
    required this.tester,
    required this.messages,
    required this.notifier,
  });

  final WidgetTester tester;
  final List<TwitchMessage> messages;
  final ValueNotifier<int> notifier;
  late final ScrollController controller;
  late final MessageBuilder builder;
  final _em = EmoteManager();

  Future<void> pump({bool keepAlive = false}) async {
    builder = MessageBuilder(
      emoteSource: _em,
      badgeService: TwitchBadgeService(),
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final atBottom = ValueNotifier(true);
    controller = ScrollController();
    final tileCache = <String, Map<String?, Widget>>{};
    addTearDown(_em.dispose);
    addTearDown(controller.dispose);
    addTearDown(atBottom.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatView(
            channel: 'test',
            messages: messages,
            tileCache: tileCache,
            atBottomNotifier: atBottom,
            messageNotifier: notifier,
            scrollController: controller,
            messageBuilder: builder,
            keepAlive: keepAlive,
            onShowUserProfile: (_, _, {displayName}) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Ids of the message rows currently built (kept off the far edge).
  List<String> builtIds() {
    final finder = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('msg-'),
    );
    return [
      for (final e in finder.evaluate())
        (e.widget.key! as ValueKey<String>).value,
    ];
  }
}

void main() {
  testWidgets('a growing insert keeps built rows in order without a crash', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 1; i <= 40; i++) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump();

    expect(
      h.builtIds().length,
      greaterThan(4),
      reason: 'need built rows to track',
    );

    // A message arrives at the head: every built row shifts one slot. The list
    // rebuilds them in place instead of asking the framework to move a keyed
    // child, which used to park a row in a slot with no layout offset.
    messages.insert(0, _msg(100));
    notifier.value++;
    await tester.pump();

    final after = h.builtIds();
    expect(after, contains('msg-100'));
    expect(
      after.toSet().length,
      after.length,
      reason: 'a row was built twice after the insert',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid grow and shrink churn does not throw', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 1; i <= 40; i++) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump();

    // Grow at the head, drop from the middle: keys move to higher and lower
    // slots in the same tick, then a tap walks every child. Guards against a
    // row being parked in a slot the sliver has no layout offset for.
    for (var round = 0; round < 40; round++) {
      messages.insert(0, _msg(1000 + round));
      if (messages.length > 24) messages.removeAt(12);
      notifier.value++;
      await tester.pump();

      await tester.tap(find.byType(ListView), warnIfMissed: false);
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'round $round threw during churn or hit test',
      );
    }
  });
}
