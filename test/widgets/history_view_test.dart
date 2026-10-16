import 'dart:collection';

import 'package:ermchat/chat/channel/messages.dart';
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

/// A tile cache that counts the tiles built into it.
class _CountingTiles extends MapBase<String?, Widget> {
  final _tiles = <String?, Widget>{};
  int built = 0;

  @override
  Widget? operator [](Object? key) => _tiles[key];

  @override
  void operator []=(String? key, Widget value) {
    built++;
    _tiles[key] = value;
  }

  @override
  void clear() => _tiles.clear();

  @override
  Iterable<String?> get keys => _tiles.keys;

  @override
  Widget? remove(Object? key) => _tiles.remove(key);
}

/// Rows, streams, clears and stream changes a test scripts. [small] is a
/// channel of [n] rows half an hour apart: less than a screen.
class _ListSource implements HistorySource {
  _ListSource(this.rows);

  _ListSource.small(int n)
    : rows = [
        for (var i = 0; i < n; i++)
          TwitchMessage(
            login: 'small',
            text: 'small $i',
            messageId: 'small-$i',
            channel: _ch,
            timestamp: t0.add(Duration(minutes: 30 * i)),
          ),
      ];

  static final DateTime t0 = DateTime.utc(2026, 10, 14, 10);
  final List<TwitchMessage> rows;
  List<HistoryStream> streamList = const [];
  final List<void Function(HistoryClear)> _clears = [];
  final List<void Function()> _streamWatchers = [];

  void clear(HistoryClear c) {
    for (final f in _clears) {
      f(c);
    }
  }

  void streamsChanged() {
    for (final f in _streamWatchers) {
      f();
    }
  }

  @override
  DateTime now() => rows.last.timestamp.add(const Duration(minutes: 30));

  @override
  Future<List<TwitchMessage>> older(DateTime time) async => [
    for (final r in rows)
      if (!r.timestamp.isAfter(time)) r,
  ];

  @override
  Future<List<TwitchMessage>> newer(DateTime time) async => [
    for (final r in rows)
      if (!r.timestamp.isBefore(time)) r,
  ];

  @override
  Future<List<TwitchMessage>> around(DateTime time) async => rows;

  @override
  Future<List<TwitchMessage>> newest() async => rows;

  @override
  Future<List<HistoryStream>> streams() async => streamList;

  @override
  Future<ActivityRail?> rail(List<HistoryStream> streams) async => ActivityRail(
    from: rows.first.timestamp,
    to: now(),
    bucket: const Duration(minutes: 30),
    counts: List.filled(rows.length + 1, 1),
  );

  @override
  void Function() watchClears(void Function(HistoryClear clear) onClear) {
    _clears.add(onClear);
    return () => _clears.remove(onClear);
  }

  @override
  void Function() watchStreams(void Function() onChange) {
    _streamWatchers.add(onChange);
    return () => _streamWatchers.remove(onChange);
  }
}

/// [rows] read in 256-row blocks, the way the archive reads: around a time
/// gives its block and the next, older gives the block holding the time, up
/// to and including it.
class _BlockSource extends _ListSource {
  _BlockSource(super.rows);

  static const int _block = 256;

  int _blockOf(DateTime t) {
    final i = rows.lastIndexWhere((r) => !r.timestamp.isAfter(t));
    return i < 0 ? 0 : i ~/ _block;
  }

  List<TwitchMessage> _blocks(int from, int to) => rows.sublist(
    (from * _block).clamp(0, rows.length),
    (to * _block).clamp(0, rows.length),
  );

  @override
  Future<List<TwitchMessage>> around(DateTime time) async {
    final b = _blockOf(time);
    return _blocks(b, b + 2);
  }

  @override
  Future<List<TwitchMessage>> older(DateTime time) async {
    final b = _blockOf(time);
    return [
      for (final r in _blocks(b, b + 1))
        if (!r.timestamp.isAfter(time)) r,
    ];
  }
}

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
  HistorySource? source,
  ValueNotifier<bool>? atBottom,
  Map<String, Map<String?, Widget>>? tileCache,
  ValueNotifier<DateTime?>? jumpRequest,
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
          tileCache: tileCache,
          jumpRequest: jumpRequest,
          atBottomNotifier: atBottom,
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

/// Opens the rail's days, as the menu's calendar does.
Future<void> _openDays(WidgetTester tester) async {
  tester.widget<HistoryScrubber>(find.byType(HistoryScrubber)).panel.value =
      true;
  await _settle(tester);
}

/// Taps the [i]th day row of the open days, from the end when negative.
Future<void> _tapDay(WidgetTester tester, int i) async {
  final rail = tester.getRect(find.byType(HistoryScrubber));
  final n = tester
      .widget<HistoryScrubber>(find.byType(HistoryScrubber))
      .rail
      .days
      .length;
  // The days button takes the rail's top 40.
  final dayH = ((rail.height - 40) / n).clamp(0.0, 40.0);
  final row = i < 0 ? n + i : i;
  await tester.tapAt(
    Offset(rail.right - 20, rail.bottom - (n - row - 0.5) * dayH),
  );
  await _settle(tester);
}

/// Drags the rail's handle through [steps], then lets go and settles.
Future<void> _scrub(WidgetTester tester, List<Offset> steps) async {
  final rail = tester.getRect(find.byType(HistoryScrubber));
  final y = tester
      .widget<HistoryScrubber>(find.byType(HistoryScrubber))
      .thumb
      .value;
  final grab = await tester.startGesture(
    Offset(rail.right - 22, rail.top + 40 + y * (rail.height - 40)),
  );
  for (final step in steps) {
    await grab.moveBy(step);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await grab.up();
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _railShown(WidgetTester tester) =>
    find.byType(HistoryScrubber).evaluate().isNotEmpty &&
    tester.widget<HistoryScrubber>(find.byType(HistoryScrubber)).visible.value;

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
    bool railShown() => _railShown(tester);
    for (var i = 0; i < 40 && !railShown(); i++) {
      await tester.fling(list, const Offset(0, 600), 6000);
      await _settle(tester);
    }
    expect(railShown(), isTrue, reason: 'flings never brought the rail in');
    // A tap on the dimmed list closes the days without moving it.
    final before = _items(tester).keys;
    await _openDays(tester);
    await tester.tapAt(tester.getRect(list).topLeft + const Offset(40, 300));
    await _settle(tester);
    expect(_items(tester).keys, before, reason: 'closing the days jumped');
    // The bar spans the last days; the oldest row is the first day's.
    await _openDays(tester);
    await _tapDay(tester, 0);
    expect(
      _items(tester).keys,
      contains('$_ch-0'),
      reason: 'the jump must land on the oldest row',
    );
    final top = tester.getRect(list).top + _inset;
    expect(
      _items(tester).top,
      moreOrLessEquals(top, epsilon: 1),
      reason: 'the jump to the top over- or undershot',
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
    double thumb() => tester
        .widget<HistoryScrubber>(find.byType(HistoryScrubber))
        .thumb
        .value;
    expect(thumb(), 0, reason: 'the thumb stopped short of the rail top');
    // From the top, the bar spans the oldest days; the newest row is back
    // through the last day, then the bar's bottom end.
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
    expect(railShown(), isTrue, reason: 'a scroll at the top hid the rail');
    await _openDays(tester);
    await _tapDay(tester, -1);
    await _scrub(tester, const [Offset(0, 20), Offset(0, 3000)]);
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      pos.pixels,
      moreOrLessEquals(pos.minScrollExtent, epsilon: 0.5),
      reason: 'the jump to the bottom stopped short of the newest row',
    );
    await tester.drag(list, const Offset(0, 300));
    await tester.drag(list, const Offset(0, -600));
    await _settle(tester);
    expect(thumb(), 1, reason: 'the thumb stopped short of the rail bottom');
  });

  testWidgets('dragging the knob past the top carries the bar older', (
    tester,
  ) async {
    await _pumpView(tester);
    final list = find.byType(CustomScrollView);
    for (var i = 0; i < 40 && !_railShown(tester); i++) {
      await tester.fling(list, const Offset(0, 600), 6000);
      await _settle(tester);
    }
    expect(_railShown(tester), isTrue, reason: 'flings never brought it in');
    final scrubber = tester.widget<HistoryScrubber>(
      find.byType(HistoryScrubber),
    );
    final start = scrubber.scale.value.from;
    await _scrub(tester, const [Offset(0, 20), Offset(0, -3000)]);
    final newest = _items(tester).keys.map((k) => int.parse(k.split('-').last));
    final landed = FakeHistory.timeOf(
      _ch,
      newest.reduce((a, b) => a > b ? a : b),
    );
    expect(
      landed.isBefore(start),
      isTrue,
      reason: 'the release stayed inside the first stretch',
    );
  });

  testWidgets('a channel shorter than the screen rests above the composer', (
    tester,
  ) async {
    final atBottom = ValueNotifier(true);
    addTearDown(atBottom.dispose);
    await _pumpView(tester, source: _ListSource.small(12), atBottom: atBottom);
    await _settle(tester);
    final list = find.byType(CustomScrollView);
    final bottom = tester.getRect(list).bottom - kOpaqueComposerGap;
    double newestBottom() => tester.getBottomLeft(_tile('small-11')).dy;
    expect(newestBottom(), moreOrLessEquals(bottom, epsilon: 1));
    // A drag past the end lands back in the same place.
    await tester.drag(list, const Offset(0, 400));
    await _settle(tester);
    expect(newestBottom(), moreOrLessEquals(bottom, epsilon: 1));
    expect(atBottom.value, isTrue, reason: 'a drag showed the button');
    // A dozen rows never bring the rail in, however old.
    await tester.drag(list, const Offset(0, 60));
    await tester.pump();
    expect(_railShown(tester), isFalse, reason: 'the rail came in');
  });

  testWidgets('a late clear fades held rows in its range, by its chatter', (
    tester,
  ) async {
    TwitchMessage row(int i, String login) => TwitchMessage(
      login: login,
      text: '$login $i',
      messageId: 'c$i',
      channel: _ch,
      timestamp: _ListSource.t0.add(Duration(minutes: i)),
    );
    final source = _ListSource([
      for (var i = 0; i < 12; i++) row(i, i.isEven ? 'spam' : 'fine'),
    ]);
    await _pumpView(tester, source: source);
    await _settle(tester);
    source.clear((
      login: 'spam',
      from: _ListSource.t0.add(const Duration(minutes: 4)),
      to: _ListSource.t0.add(const Duration(minutes: 8)),
    ));
    await tester.pump();
    expect(
      {
        for (final r in source.rows)
          if (r.deleted) r.messageId,
      },
      {'c4', 'c6', 'c8'},
      reason: 'only the chatter\'s rows inside the range fade',
    );
    expect(
      tester.widget<ChatMessageTile>(_tile('c6')).message.deleted,
      isTrue,
      reason: 'the visible tile kept its old look',
    );
  });

  testWidgets('a stream that reopens drops its stale end marker', (
    tester,
  ) async {
    final source = _ListSource.small(10);
    final t0 = _ListSource.t0;
    HistoryStream stream({required bool live}) => HistoryStream(
      id: 's1',
      start: t0.add(const Duration(minutes: 45)),
      end: live ? source.now() : t0.add(const Duration(minutes: 135)),
      title: 'Speedrun',
      game: 'Zelda',
      live: live,
    );
    source.streamList = [stream(live: false)];
    await _pumpView(tester, source: source);
    await _settle(tester);
    expect(find.textContaining('Stream ended'), findsOneWidget);
    source.streamList = [stream(live: true)];
    source.streamsChanged();
    await _settle(tester);
    expect(
      find.textContaining('Stream ended'),
      findsNothing,
      reason: 'the page kept the end the archive took back',
    );
    expect(find.textContaining('Speedrun'), findsOneWidget);
  });

  testWidgets('a gap note held by the archive and the buffer shows once', (
    tester,
  ) async {
    final source = _ListSource.small(6);
    final at = source.rows[3].timestamp.subtract(
      const Duration(milliseconds: 1),
    );
    TwitchMessage note() => TwitchMessage(
      login: '',
      text: 'History: Not all messages retrieved',
      isSystem: true,
      messageId: '${Messages.historyGapIdPrefix}${at.millisecondsSinceEpoch}',
      channel: _ch,
      timestamp: at,
    );
    source.rows.insert(3, note());
    // The live buffer, newest first, still holds its own copy.
    final buffer = [
      for (final r in source.rows.reversed)
        if (r.isSystem) note() else r,
    ];
    await _pumpView(tester, source: source, live: () => buffer);
    await _settle(tester);
    expect(find.textContaining('Not all messages retrieved'), findsOneWidget);
  });

  testWidgets('switching channels comes back at the bottom, no button', (
    tester,
  ) async {
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
    const channels = [FakeHistory.testChannel, FakeHistory.denseChannel];
    final page = ValueNotifier(0);
    addTearDown(page.dispose);
    final versions = [ValueNotifier(0), ValueNotifier(0)];
    final atBottom = [ValueNotifier(true), ValueNotifier(true)];
    final flashes = [0, 0];
    for (var i = 0; i < 2; i++) {
      addTearDown(versions[i].dispose);
      addTearDown(atBottom[i].dispose);
      atBottom[i].addListener(() {
        if (!atBottom[i].value) flashes[i]++;
      });
    }
    // Each channel's buffer, newest first, capped like the kernel's.
    final buffers = [<TwitchMessage>[], <TwitchMessage>[]];
    var n = 0;
    void arrive(int i, int count) {
      for (var k = 0; k < count; k++) {
        n++;
        buffers[i].insert(
          0,
          TwitchMessage(
            login: 'live',
            text: 'live $n',
            messageId: 'live-$n',
            channel: channels[i],
            timestamp: FakeHistory.now.add(Duration(seconds: n)),
          ),
        );
      }
      if (buffers[i].length > 50) buffers[i].removeRange(50, buffers[i].length);
      versions[i].value++;
    }

    arrive(0, 20);
    arrive(1, 20);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PageView(
            onPageChanged: (i) => page.value = i,
            children: [
              for (var i = 0; i < 2; i++)
                ValueListenableBuilder<int>(
                  valueListenable: page,
                  // Like the app, only the active page follows its buffer.
                  builder: (_, active, _) => HistoryView(
                    key: ValueKey(channels[i]),
                    channel: channels[i],
                    source: FakeHistorySource(channels[i]),
                    rows: ChatRows(
                      channel: channels[i],
                      messageBuilder: builder,
                      onShowUserProfile: (_, _, {displayName}) {},
                    ),
                    atBottomNotifier: atBottom[i],
                    live: () => buffers[i],
                    liveVersion: active == i ? versions[i] : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    ScrollPosition posOf(int i) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(ValueKey(channels[i])),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    for (var round = 0; round < 3; round++) {
      final from = round.isEven ? 0 : 1;
      final to = 1 - from;
      await tester.fling(
        find.byType(PageView),
        Offset(from == 0 ? -300 : 300, 0),
        2000,
      );
      await _settle(tester);
      // The page left behind keeps getting chat, past its whole buffer.
      arrive(from, 80);
      arrive(to, 3);
      await _settle(tester);
      final pos = posOf(to);
      expect(
        pos.pixels,
        moreOrLessEquals(pos.minScrollExtent, epsilon: 0.5),
        reason: 'round $round: landed above the bottom of ${channels[to]}',
      );
      expect(atBottom[to].value, isTrue, reason: 'round $round: button shows');
    }
    expect(flashes, [0, 0], reason: 'the button flashed during a switch');
  });

  testWidgets('thousands of rows landing while following build one screen', (
    tester,
  ) async {
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
            timestamp: FakeHistory.now.add(Duration(seconds: n)),
          ),
        );
      }
      version.value++;
    }

    final tiles = _CountingTiles();
    arrive(5);
    await _pumpView(
      tester,
      live: () => buffer,
      liveVersion: version,
      tileCache: {_ch: tiles},
    );
    await _settle(tester);
    // A history restore landing at once, like a busy channel's on startup.
    tiles.built = 0;
    arrive(3000);
    await tester.pump();
    expect(
      tiles.built,
      lessThan(200),
      reason: 'the frame laid out the whole batch to reach the newest row',
    );
    expect(_tile('live-$n'), findsOneWidget, reason: 'newest row not shown');
  });

  testWidgets('a jump request shows that message, on open or later', (
    tester,
  ) async {
    final jump = ValueNotifier<DateTime?>(FakeHistory.timeOf(_ch, 1000));
    addTearDown(jump.dispose);
    await _pumpView(tester, jumpRequest: jump);
    await _settle(tester);
    expect(_items(tester).keys, contains('$_ch-1000'), reason: 'on open');
    expect(jump.value, isNull, reason: 'the request is consumed');
    jump.value = FakeHistory.timeOf(_ch, 200);
    await _settle(tester);
    expect(_items(tester).keys, contains('$_ch-200'), reason: 'while open');
    expect(jump.value, isNull);
  });

  testWidgets('a jump just past a block start keeps the rows above it', (
    tester,
  ) async {
    // Reads come in 256-row blocks like the archive's, and a read for older
    // rows includes its own time. The jump's first look above the loaded
    // block found only that block's first row and took it for the oldest.
    final rows = [
      for (var i = 0; i < 1000; i++)
        TwitchMessage(
          login: 'b',
          text: 'block row $i',
          messageId: 'b-$i',
          channel: _ch,
          timestamp: _ListSource.t0.add(Duration(minutes: i)),
        ),
    ];
    final jump = ValueNotifier<DateTime?>(rows[266].timestamp);
    addTearDown(jump.dispose);
    await _pumpView(tester, source: _BlockSource(rows), jumpRequest: jump);
    await _settle(tester);
    expect(_items(tester).keys, contains('b-266'));
    final list = find.byType(CustomScrollView);
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, 700));
      await _settle(tester);
    }
    final above = _items(
      tester,
    ).keys.any((k) => int.parse(k.split('-').last) < 256);
    expect(above, isTrue, reason: 'the rows above the block were lost');
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
