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
  final _em = EmoteManager();

  Future<void> pump({bool keepAlive = true}) async {
    final builder = MessageBuilder(
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
  testWidgets('hold keeps reading position across sequential arrivals', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 80; i >= 1; i--) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump();

    // A real device fling leaves the reader deep in the backlog.
    await tester.fling(find.byType(ListView), const Offset(0, 900), 2000);
    await tester.pumpAndSettle();

    final tracked = h.visibleRows().keys.take(6).toList();
    expect(tracked, isNotEmpty, reason: 'need rows on screen to assert a hold');
    final before = h.visibleRows();
    final offsetBefore = h.controller.offset;

    // Six arrivals, one per frame, mixed heights.
    for (var k = 0; k < 6; k++) {
      h.insertHead([_msg(81 + k)]);
      await tester.pump();
      await tester.pump();
    }

    final after = h.visibleRows();
    for (final key in tracked) {
      expect(
        after[key],
        isNotNull,
        reason: '$key should still be built after the hold',
      );
      expect(
        after[key],
        moreOrLessEquals(before[key]!, epsilon: 0.5),
        reason: '$key moved while the reader was scrolled up',
      );
    }
    // The list compensated by moving its offset toward the new head.
    expect(h.controller.offset, greaterThan(offsetBefore));
  });

  testWidgets('hold keeps reading position for a bulk arrival', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 80; i >= 1; i--) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump();

    await tester.fling(find.byType(ListView), const Offset(0, 900), 2000);
    await tester.pumpAndSettle();

    final tracked = h.visibleRows().keys.take(6).toList();
    expect(tracked, isNotEmpty);
    final before = h.visibleRows();
    final offsetBefore = h.controller.offset;

    // Five rows land in the same tick, so the hold must shift the whole batch.
    h.insertHead([for (var k = 0; k < 5; k++) _msg(81 + k)]);
    await tester.pump();
    await tester.pump();

    final after = h.visibleRows();
    for (final key in tracked) {
      expect(after[key], isNotNull);
      expect(
        after[key],
        moreOrLessEquals(before[key]!, epsilon: 0.5),
        reason: '$key moved on a bulk arrival',
      );
    }
    expect(h.controller.offset, greaterThan(offsetBefore));
  });

  testWidgets('hold works on a PageStorage-backed list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 80; i >= 1; i--) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    // keepAlive false routes through the PageStorageKey branch channel pages use.
    await h.pump(keepAlive: false);

    await tester.fling(find.byType(ListView), const Offset(0, 900), 2000);
    await tester.pumpAndSettle();

    final tracked = h.visibleRows().keys.take(6).toList();
    expect(tracked, isNotEmpty);
    final before = h.visibleRows();

    h.insertHead([_msg(81)]);
    await tester.pump();
    await tester.pump();

    final after = h.visibleRows();
    for (final key in tracked) {
      expect(after[key], isNotNull);
      expect(
        after[key],
        moreOrLessEquals(before[key]!, epsilon: 0.5),
        reason: '$key moved on a PageStorage-backed list',
      );
    }
  });

  testWidgets('hold works when the buffer is at cap (length unchanged)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier(0);
    addTearDown(notifier.dispose);
    final messages = <TwitchMessage>[for (var i = 80; i >= 1; i--) _msg(i)];
    final h = _Harness(tester: tester, messages: messages, notifier: notifier);
    await h.pump();

    await tester.fling(find.byType(ListView), const Offset(0, 900), 2000);
    await tester.pumpAndSettle();

    final tracked = h.visibleRows().keys.take(6).toList();
    expect(tracked, isNotEmpty);
    final before = h.visibleRows();
    final offsetBefore = h.controller.offset;

    // A full buffer keeps its length while every arrival still shifts the view.
    for (var k = 0; k < 6; k++) {
      h.insertHeadAtCap([_msg(81 + k)]);
      await tester.pump();
      await tester.pump();
    }

    final after = h.visibleRows();
    for (final key in tracked) {
      expect(after[key], isNotNull);
      expect(
        after[key],
        moreOrLessEquals(before[key]!, epsilon: 0.5),
        reason: '$key moved while the buffer was at cap',
      );
    }
    expect(h.controller.offset, greaterThan(offsetBefore));
  });
}
