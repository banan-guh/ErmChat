import 'package:ermchat/l10n/l10n.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/util/fake_history.dart';
import 'package:ermchat/util/history_timeline.dart';
import 'package:ermchat/widgets/chat_message_tile.dart';
import 'package:ermchat/widgets/chat_rows.dart';
import 'package:ermchat/widgets/glass_chrome.dart';
import 'package:ermchat/widgets/history_view.dart';
import 'package:ermchat/widgets/history_scrubber.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _inset = 50;
const String _ch = FakeHistory.testChannel;

/// Has no rail on the first read, like an archive with nothing sealed yet.
class _EmptyFirstRail extends FakeHistorySource {
  _EmptyFirstRail(super.channel);

  bool _first = true;

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async {
    if (!_first) return super.rail(streams);
    _first = false;
    return null;
  }
}

Future<void> _pumpView(
  WidgetTester tester, {
  List<TwitchMessage> Function()? live,
  Listenable? liveVersion,
  FakeHistorySource? source,
}) async {
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
        body: HistoryView(
          channel: _ch,
          source: source ?? FakeHistorySource(_ch),
          rows: ChatRows(
            channel: _ch,
            messageBuilder: builder,
            onShowUserProfile: (_, _, {displayName}) {},
          ),
          debugControls: true,
          live: live,
          liveVersion: liveVersion,
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
  final keyed = find.byWidgetPredicate(
    (w) => w is KeyedSubtree || w is RowGate,
  );
  for (final e in keyed.evaluate()) {
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

Finder _tile(String id) => find.byWidgetPredicate(
  (w) => w is ChatMessageTile && w.message.messageId == id,
);

void main() {
  testWidgets('live rows: follow pins newest, a paused reader stays still', (
    tester,
  ) async {
    final version = ValueNotifier(0);
    addTearDown(version.dispose);
    final buffer = <TwitchMessage>[];
    var n = 0;
    TwitchMessage row([String? id]) => TwitchMessage(
      login: 'live',
      text: 'live ${n++}',
      messageId: id ?? 'live-$n',
      channel: _ch,
      timestamp: FakeHistory.now.add(Duration(seconds: n)),
    );
    void arrive(int count) {
      for (var i = 0; i < count; i++) {
        buffer.insert(0, row());
      }
      version.value++;
    }

    arrive(30);
    await _pumpView(tester, live: () => buffer, liveVersion: version);
    await _settle(tester);
    final bottom =
        tester.getRect(find.byType(CustomScrollView)).bottom -
        kOpaqueComposerGap;
    expect(
      tester.getBottomLeft(_tile(buffer.first.messageId!)).dy,
      moreOrLessEquals(bottom, epsilon: 1),
      reason: 'the newest live row starts at the bottom',
    );

    arrive(3);
    await tester.pump();
    expect(
      tester.getBottomLeft(_tile(buffer.first.messageId!)).dy,
      moreOrLessEquals(bottom, epsilon: 1),
      reason: 'following keeps the newest row at the bottom',
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await _settle(tester);
    // The reader's row: a live row near the middle of the viewport.
    final view = tester.getRect(find.byType(CustomScrollView));
    final at = buffer.indexWhere((m) {
      final f = _tile(m.messageId!);
      return f.evaluate().isNotEmpty &&
          (tester.getCenter(f).dy - view.center.dy).abs() < 40;
    });
    expect(at, greaterThan(0), reason: 'no live row mid-viewport');
    final reading = buffer[at].messageId!;
    final y = tester.getTopLeft(_tile(reading)).dy;
    arrive(3);
    await tester.pump();
    expect(
      tester.getTopLeft(_tile(reading)).dy,
      y,
      reason: 'arrivals below a paused reader moved the row being read',
    );

    // A late row lands just older than the row being read.
    final late = TwitchMessage(
      login: 'live',
      text: 'late one',
      messageId: 'late',
      channel: _ch,
      timestamp: buffer[at + 4].timestamp,
    );
    buffer.insert(at + 4, late);
    version.value++;
    await tester.pump();
    expect(_tile('late'), findsOneWidget);
    expect(
      tester.getTopLeft(_tile(reading)).dy,
      y,
      reason: 'a middle insert moved the row being read',
    );

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -2000),
      4000,
    );
    await _settle(tester);
    arrive(1);
    await tester.pump();
    expect(
      tester.getBottomLeft(_tile(buffer.first.messageId!)).dy,
      moreOrLessEquals(bottom, epsilon: 1),
      reason: 'resting on the newest row resumes following',
    );
  });

  testWidgets('a live buffer above the window cap keeps following', (
    tester,
  ) async {
    const limit = 4000;
    final version = ValueNotifier(0);
    addTearDown(version.dispose);
    final buffer = <TwitchMessage>[];
    var n = 0;
    void arrive(int count) {
      for (var i = 0; i < count; i++) {
        n++;
        buffer.insert(
          0,
          TwitchMessage(
            login: 'live',
            text: 'live $n',
            messageId: 'live-$n',
            channel: _ch,
            timestamp: FakeHistory.now.add(Duration(milliseconds: 100 * n)),
          ),
        );
      }
      if (buffer.length > limit) buffer.removeRange(limit, buffer.length);
      version.value++;
    }

    arrive(limit);
    await _pumpView(tester, live: () => buffer, liveVersion: version);
    await _settle(tester);
    // Enough arrivals to re-anchor and trim several times.
    for (var i = 0; i < 200; i++) {
      arrive(10);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _settle(tester);
    expect(
      tester.getBottomLeft(_tile(buffer.first.messageId!)).dy,
      moreOrLessEquals(
        tester.getRect(find.byType(CustomScrollView)).bottom -
            kOpaqueComposerGap,
        epsilon: 1,
      ),
      reason: 'a trim into the live rows broke the live sync',
    );
  });

  testWidgets('a drag held at the bottom while rows arrive keeps following', (
    tester,
  ) async {
    final version = ValueNotifier(0);
    addTearDown(version.dispose);
    final buffer = <TwitchMessage>[];
    var n = 0;
    void arrive() {
      n++;
      buffer.insert(
        0,
        TwitchMessage(
          login: 'live',
          text: 'live $n',
          messageId: 'live-$n',
          channel: _ch,
          timestamp: FakeHistory.now.add(Duration(seconds: n)),
        ),
      );
      version.value++;
    }

    for (var i = 0; i < 60; i++) {
      arrive();
    }
    await _pumpView(tester, live: () => buffer, liveVersion: version);
    await _settle(tester);
    final list = find.byType(CustomScrollView);
    final g = await tester.startGesture(tester.getCenter(list));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 3; i++) {
      arrive();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await _settle(tester);
    arrive();
    await tester.pump();
    expect(
      tester.getBottomLeft(_tile(buffer.first.messageId!)).dy,
      moreOrLessEquals(
        tester.getRect(list).bottom - kOpaqueComposerGap,
        epsilon: 1,
      ),
      reason: 'released at the bottom but stopped following',
    );
  });

  testWidgets('scrolling down from history reattaches the live rows', (
    tester,
  ) async {
    final version = ValueNotifier(0);
    addTearDown(version.dispose);
    final buffer = [
      for (var i = 20; i > 0; i--)
        TwitchMessage(
          login: 'live',
          text: 'live $i',
          messageId: 'live-$i',
          channel: _ch,
          timestamp: FakeHistory.now.add(Duration(seconds: i)),
        ),
    ];
    await _pumpView(tester, live: () => buffer, liveVersion: version);
    await tester.tap(find.text('1d'));
    await _settle(tester);
    expect(_tile('live-20'), findsNothing);
    final list = find.byType(CustomScrollView);
    for (var i = 0; i < 30 && _tile('live-20').evaluate().isEmpty; i++) {
      await tester.fling(list, const Offset(0, -600), 6000);
      await _settle(tester);
    }
    expect(
      _tile('live-20'),
      findsOneWidget,
      reason: 'the newest live row never came back',
    );
    buffer.insert(
      0,
      TwitchMessage(
        login: 'live',
        text: 'live 21',
        messageId: 'live-21',
        channel: _ch,
        timestamp: FakeHistory.now.add(const Duration(seconds: 21)),
      ),
    );
    version.value++;
    await tester.pump();
    expect(
      tester.getBottomLeft(_tile('live-21')).dy,
      moreOrLessEquals(
        tester.getRect(list).bottom - kOpaqueComposerGap,
        epsilon: 1,
      ),
      reason: 'resting on the reattached tail follows new rows',
    );
  });

  testWidgets('scroll past the oldest row after a rail jump to the top', (
    tester,
  ) async {
    // A fresh archive has no rail at first paint; scrolling builds it later.
    await _pumpView(tester, source: _EmptyFirstRail(_ch));
    // Long flings up bring the rail in.
    final list = find.byType(CustomScrollView);
    bool railShown() =>
        find.byType(HistoryScrubber).evaluate().isNotEmpty &&
        tester
                .widget<AnimatedOpacity>(
                  find.descendant(
                    of: find.byType(HistoryScrubber),
                    matching: find.byType(AnimatedOpacity),
                  ),
                )
                .opacity ==
            1;
    for (var i = 0; i < 40 && !railShown(); i++) {
      await tester.fling(list, const Offset(0, 600), 6000);
      await _settle(tester);
    }
    expect(railShown(), isTrue, reason: 'flings never brought the rail in');
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

  testWidgets('a re-anchor moves visible rows instead of rebuilding them', (
    tester,
  ) async {
    await _pumpView(tester);
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    Map<String, (Element, double)> visible() => {
      for (final e in find.byType(RowGate).evaluate())
        if (e.widget.key case ValueKey<String>(
          :final value,
        ) when (e.renderObject! as RenderBox).attached)
          value: (e, tester.getTopLeft(find.byWidget(e.widget)).dy),
    };
    final gesture = await tester.startGesture(const Offset(200, 400));
    var reanchored = false;
    for (var i = 0; i < 2000 && !reanchored; i++) {
      final before = visible();
      final px = pos.pixels;
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      if (pos.pixels > px - 1000) continue;
      // The correction landed; the next layout applies the new anchor.
      reanchored = true;
      await tester.pump(const Duration(milliseconds: 16));
      final after = visible();
      final both = before.keys.where(after.containsKey).toList();
      expect(both, isNotEmpty);
      for (final k in both) {
        expect(
          identical(after[k]!.$1, before[k]!.$1),
          isTrue,
          reason: 'row $k was rebuilt by the re-anchor',
        );
        expect(
          after[k]!.$2,
          moreOrLessEquals(before[k]!.$2 + 30, epsilon: 0.5),
          reason: 'row $k moved on screen',
        );
      }
    }
    await gesture.up();
    expect(reanchored, isTrue, reason: 'the drag never re-anchored');
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
