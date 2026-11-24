import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/widgets/chat_view.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Variable-height rows so a wrong hold shows up as motion, not a rounding blip.
TwitchMessage _msg(int i) => TwitchMessage(
  login: 'user$i',
  text: (i % 4 == 0)
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
  final tileCache = <String, Map<String?, Widget>>{};
  final _em = EmoteManager();

  Future<void> pump({bool keepAlive = true, bool keepPosition = true}) async {
    final builder = MessageBuilder(
      emoteSource: _em,
      badgeService: TwitchBadgeService(),
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final atBottom = ValueNotifier(true);
    controller = ScrollController();
    addTearDown(_em.dispose);
    addTearDown(controller.dispose);
    addTearDown(atBottom.dispose);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
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
            keepPosition: keepPosition,
            onShowUserProfile: (_, _, _, {displayName}) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Global y of every currently built message row, keyed by message id.
  Map<String, double> visibleRows() {
    final rows = <String, double>{};
    final finder = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('msg-'),
    );
    for (final element in finder.evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.attached) continue;
      rows[(element.widget.key! as ValueKey<String>).value] = box
          .localToGlobal(Offset.zero)
          .dy;
    }
    return rows;
  }

  void insertHead(List<TwitchMessage> arrivals) {
    for (final m in arrivals) {
      messages.insert(0, m);
    }
    notifier.value++;
  }

  // Full buffer: one arrival in, oldest out, so the length never changes.
  void insertHeadAtCap(List<TwitchMessage> arrivals) {
    for (final m in arrivals) {
      messages.insert(0, m);
      messages.removeLast();
    }
    notifier.value++;
  }
}

void main() {
  Future<_Harness> pumpDeep(
    WidgetTester tester, {
    int count = 80,
    bool keepAlive = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = count; i >= 1; i--) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump(keepAlive: keepAlive);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 900),
      2000,
    );
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('hold keeps reading position across buffer changes', (
    tester,
  ) async {
    for (final scenario in [
      'sequential',
      'bulk',
      'pageStorage',
      'cap',
      'removal',
    ]) {
      final h = await pumpDeep(tester, keepAlive: scenario != 'pageStorage');
      final tracked = h.visibleRows().keys.take(6).toList();
      expect(tracked, isNotEmpty, reason: scenario);
      final before = h.visibleRows();
      final offsetBefore = h.controller.offset;

      switch (scenario) {
        case 'sequential':
          for (var k = 0; k < 6; k++) {
            h.insertHead([_msg(81 + k)]);
            await tester.pump();
            await tester.pump();
          }
        case 'bulk':
          h.insertHead([for (var k = 0; k < 5; k++) _msg(81 + k)]);
          await tester.pump();
          await tester.pump();
        case 'pageStorage':
          h.insertHead([_msg(81)]);
          await tester.pump();
          await tester.pump();
        case 'cap':
          for (var k = 0; k < 6; k++) {
            h.insertHeadAtCap([_msg(81 + k)]);
            await tester.pump();
            await tester.pump();
          }
        case 'removal':
          h.messages.removeAt(0);
          h.notifier.value++;
          await tester.pump();
          await tester.pump();
      }

      final after = h.visibleRows();
      for (final key in tracked) {
        expect(after[key], isNotNull, reason: '$scenario: $key');
        expect(
          after[key],
          moreOrLessEquals(before[key]!, epsilon: 0.5),
          reason: '$scenario: $key moved while the reader was scrolled up',
        );
      }
      if (scenario == 'sequential' || scenario == 'cap') {
        expect(
          h.controller.offset,
          greaterThan(offsetBefore),
          reason: '$scenario did not compensate for the new head',
        );
      }
    }
  });

  testWidgets('FAB reaches the bottom through races and active arrivals', (
    tester,
  ) async {
    for (final scenario in ['deep', 'tapFrame', 'pending', 'active']) {
      final h = await pumpDeep(tester, count: 400);
      expect(h.controller.offset, greaterThan(1000), reason: scenario);
      final fab = find.byKey(const ValueKey('scroll_down'));
      expect(fab, findsOneWidget);

      switch (scenario) {
        case 'deep':
          await tester.tap(fab);
          await tester.pump();
          await tester.pump();
        case 'tapFrame':
          await tester.tap(fab);
          h.insertHead([_msg(999)]);
          await tester.pump();
          await tester.pump();
        case 'pending':
          h.insertHead([_msg(999)]);
          await tester.pump();
          await tester.tap(fab);
          await tester.pump();
          await tester.pump();
        case 'active':
          for (var k = 0; k < 3; k++) {
            h.insertHead([_msg(600 + k)]);
            await tester.pump();
          }
          await tester.tap(fab);
          for (var k = 0; k < 6; k++) {
            h.insertHead([_msg(700 + k)]);
            await tester.pump();
          }
          await tester.pump();
      }

      expect(
        h.controller.offset,
        lessThanOrEqualTo(0.5),
        reason: '$scenario did not land at the bottom',
      );
    }
  });

  testWidgets('FAB from the oldest end jumps without building every row', (
    tester,
  ) async {
    final h = await pumpDeep(tester, count: 500);
    h.controller.jumpTo(h.controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(h.controller.offset, greaterThan(1000));

    h.tileCache.clear();
    await tester.tap(find.byKey(const ValueKey('scroll_down')));
    await tester.pump();
    await tester.pump();

    expect(h.controller.offset, lessThanOrEqualTo(0.5));
    expect(
      h.tileCache['test']!.length,
      lessThan(100),
      reason: 'the jump built every row between the oldest and the newest',
    );
  });
}
