import 'package:ermchat/l10n/l10n.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/util/fake_history.dart';
import 'package:ermchat/widgets/chat_message_tile.dart';
import 'package:ermchat/widgets/fake_history_view.dart';
import 'package:ermchat/widgets/history_scrubber.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _inset = 50;
const String _ch = FakeHistory.testChannel;

Future<void> _pumpView(WidgetTester tester) async {
  FakeHistory.loadDelay = Duration.zero;
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final em = EmoteManager();
  addTearDown(em.dispose);
  final builder = MessageBuilder(
    emoteSource: em,
    badgeService: TwitchBadgeService(),
    thirdPartyBadgeService: ThirdPartyBadgeService(),
    onShowEmoteSheet: (_) {},
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FakeHistoryView(
          channel: _ch,
          messageBuilder: builder,
          topPadding: _inset,
        ),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump();
}

/// Top and bottom of the built list items, in global coordinates.
({double top, double bottom, Set<String> keys}) _items(WidgetTester tester) {
  var top = double.infinity;
  var bottom = double.negativeInfinity;
  final keys = <String>{};
  final scrollable = tester.getRect(find.byType(CustomScrollView));
  for (final e in find.byType(KeyedSubtree).evaluate()) {
    final key = e.widget.key;
    if (key is! ValueKey<String>) continue;
    final box = e.renderObject;
    if (box is! RenderBox || !box.attached) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.bottom < scrollable.top || rect.top > scrollable.bottom) continue;
    keys.add(key.value);
    if (rect.top < top) top = rect.top;
    if (rect.bottom > bottom) bottom = rect.bottom;
  }
  return (top: top, bottom: bottom, keys: keys);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('scroll past the oldest row after a rail jump to the top', (
    tester,
  ) async {
    await _pumpView(tester);
    // Long flings up bring the rail in.
    final list = find.byType(CustomScrollView);
    for (
      var i = 0;
      i < 40 && find.byType(HistoryScrubber).evaluate().isEmpty;
      i++
    ) {
      await tester.fling(list, const Offset(0, 600), 6000);
      await _settle(tester);
    }
    expect(find.byType(HistoryScrubber), findsOneWidget);
    // Drag the thumb past the top of the rail: a jump to row 0.
    await tester.drag(find.byType(HistoryScrubber), const Offset(0, -3000));
    await _settle(tester);
    expect(
      _items(tester).keys,
      contains('$_ch-0'),
      reason: 'the jump must land on the oldest row',
    );
    // Dragging further toward older rows must not reveal empty space.
    for (var i = 0; i < 4; i++) {
      await tester.drag(list, const Offset(0, 700));
      await _settle(tester);
    }
    final it = _items(tester);
    expect(
      it.top,
      lessThanOrEqualTo(_inset + 1),
      reason: 'scrolled past the oldest row into empty space',
    );
  });

  testWidgets('repeat jump does nothing when its window is loaded', (
    tester,
  ) async {
    await _pumpView(tester);
    await tester.tap(find.text('7d'));
    await _settle(tester);
    final list = find.byType(CustomScrollView);
    final row = find.byType(ChatMessageTile).first;
    final key = tester.widget<ChatMessageTile>(row).message.messageId!;
    final target = find.byWidgetPredicate(
      (w) => w is ChatMessageTile && w.message.messageId == key,
    );
    final landed = tester.getTopLeft(target).dy;
    // A second jump targets the same anchor and window.
    await tester.drag(list, const Offset(0, -200));
    await _settle(tester);
    expect(tester.getTopLeft(target).dy, isNot(landed));
    await tester.tap(find.text('7d'));
    await _settle(tester);
    expect(
      tester.getTopLeft(target).dy,
      landed,
      reason: 'the second jump left the list where it was',
    );
  });
}
