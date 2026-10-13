import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../util/fake_history.dart';
import '../util/history_timeline.dart';
import '../util/log.dart';
import '../util/perf_probe.dart';
import '../util/timestamp_formatter.dart';
import 'chat_message_tile.dart';
import 'glass_chrome.dart';
import 'history_scrubber.dart';
import 'message_builder.dart';

/// Prototype of the windowed history list over [FakeHistory] data, shown for
/// the fake channels when `ERMCHAT_FAKE_HISTORY` is on.
///
/// One reversed `CustomScrollView` with a `center` sliver. The center sliver
/// holds items older than [_anchor], the sliver before it holds newer items.
/// An item is a row or a derived marker (stream start/end, day, empty
/// stretch) that sits before its row in time; markers are computed per block
/// from row times, so a block load, trim or re-anchor never duplicates them.
/// Blocks load at the edge being approached and drop from the far edge. When
/// the viewport drifts [_reanchorRows] items from the anchor, the anchor moves
/// to the viewport and `correctBy` keeps the content still, so the far ends
/// can trim without moving anything on screen. A time rail ([HistoryScrubber])
/// fades in after a long scroll and jumps through [_jumpToRow].
class FakeHistoryView extends StatefulWidget {
  const FakeHistoryView({
    super.key,
    required this.channel,
    required this.messageBuilder,
    this.topPadding = 0,
    this.showTimestamp = true,
    this.timestampFormat = kDefaultTimestampFormat,
    this.textScale = 1.0,
    this.lineSeparator = false,
  });

  final String channel;
  final MessageBuilder messageBuilder;
  final double topPadding;
  final bool showTimestamp;
  final String timestampFormat;
  final double textScale;
  final bool lineSeparator;

  @override
  State<FakeHistoryView> createState() => _FakeHistoryViewState();
}

/// A decoded block with its derived markers, keyed by the row they precede.
class _Block {
  const _Block(this.rows, this.markers);

  final List<TwitchMessage> rows;
  final Map<int, List<HistoryMarker>> markers;
}

/// One list item: a row, or a marker before [row]. [start] is true for the
/// item the sliver may begin at when the anchor moves: the first of a row's
/// group in time order (newer sliver) or the row itself (older sliver).
class _Item {
  const _Item(this.row, this.marker, this.start);

  final int row;
  final HistoryMarker? marker;
  final bool start;
}

class _FakeHistoryViewState extends State<FakeHistoryView> {
  static const int _cap = 3000;
  static const int _bs = FakeHistory.blockSize;

  /// Rows between viewport and anchor that trigger a re-anchor.
  static const int _reanchorRows = 800;

  /// Rows kept on each side of the viewport when trimming.
  static const int _keepNear = 500;

  /// Rows scrolled up from newest before the rail appears.
  static const int _railAfterRows = 500;

  /// Ballistic speed (px/s) that counts as a hard fling.
  static const double _railFlingSpeed = 3000;
  static const int _railIdleMs = 1500;
  static const Duration _railBucket = Duration(minutes: 5);

  /// Decoded landing blocks kept from rail drags.
  static const int _prefetchKeep = 4;

  static final Map<String, int> _counters = {};
  static final Map<String, ActivityRail> _rails = {};
  static _FakeHistoryViewState? _active;

  final ScrollController _controller = ScrollController();
  final GlobalKey _olderKey = GlobalKey();
  final GlobalKey _newerKey = GlobalKey();
  final Map<int, _Block> _blocks = {};
  final Map<int, Future<_Block>> _prefetched = {};
  final Set<int> _inFlight = {};
  final Stopwatch _open = Stopwatch()..start();
  List<_Item> _newerItems = const [];
  List<_Item> _olderItems = const [];

  // Rail state. Notifiers drive the scrubber so showing, hiding and moving
  // the thumb never rebuild the list.
  final ValueNotifier<ActivityRail?> _railReady = ValueNotifier(null);
  final ValueNotifier<double> _thumb = ValueNotifier(1);
  final ValueNotifier<bool> _railVisible = ValueNotifier(false);
  final ValueNotifier<bool> _peek = ValueNotifier(false);
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _idleTimer;
  int _idleDeadline = 0;
  bool _railDragging = false;
  bool _scrolled = false;
  int _lastPrefetch = -1;
  String? _fmtLocale;
  DateFormat? _dayFmt;
  DateFormat? _shortDayFmt;

  late final int _total = FakeHistory.rowCount(widget.channel);
  late final int _lastBlock = FakeHistory.blockCount(widget.channel) - 1;
  late final List<HistoryStream> _streams = FakeHistory.streams(widget.channel);

  /// Loaded block range, inclusive; empty while [_hiBlock] < [_loBlock].
  int _loBlock = 0;
  int _hiBlock = -1;

  /// Row at the boundary: older rows sit above it, this row and newer below.
  int _anchor = 0;
  int _epoch = 0;
  bool _maintainScheduled = false;
  bool _firstPainted = false;
  String _status = '';

  int get _loRow => _loBlock * _bs;
  int get _hiRow =>
      _hiBlock < _loBlock ? _loRow : ((_hiBlock + 1) * _bs).clamp(0, _total);
  int get _windowRows => _hiRow - _loRow;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _active = this;
    PerfProbe.counters(_counters);
    PerfProbe.gauge('hwin', () => _active?._windowRows ?? 0);
    if (PerfProbe.enabled) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    }
    _jumpToRow(_total);
  }

  @override
  void dispose() {
    if (identical(_active, this)) _active = null;
    if (PerfProbe.enabled) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    _idleTimer?.cancel();
    _controller.dispose();
    _railReady.dispose();
    _thumb.dispose();
    _railVisible.dispose();
    _peek.dispose();
    super.dispose();
  }

  void _onScroll() {
    _scrolled = true;
    _scheduleMaintain();
  }

  void _count(String key, [int n = 1]) =>
      _counters[key] = (_counters[key] ?? 0) + n;

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final ms = t.totalSpan.inMilliseconds;
      if (ms > 16) _count('hjank');
      if (ms > (_counters['hworst'] ?? 0)) _counters['hworst'] = ms;
    }
  }

  void _log(String message) {
    logDebug('[hist] $message');
    if (PerfProbe.enabled) PerfLog.I.record('HIST', message);
  }

  ScrollPosition? get _pos =>
      _controller.hasClients ? _controller.position : null;

  // ---- Jumps ---------------------------------------------------------------

  /// Replaces the window with blocks around [row] and puts the boundary there:
  /// older rows above, [row] and newer below. Awaits the blocks first so the
  /// old content stays up until the new content is ready.
  Future<void> _jumpToRow(int row, {double fraction = 0}) async {
    final epoch = ++_epoch;
    _inFlight.clear();
    final target = row.clamp(0, _total);
    final tb = (target >= _total ? _total - 1 : target) ~/ _bs;
    final lo = (tb - 1).clamp(0, _lastBlock);
    final hi = (tb + 1).clamp(0, _lastBlock);
    final sw = Stopwatch()..start();
    final loaded = await Future.wait([
      for (var b = lo; b <= hi; b++) _fetch(b),
    ]);
    if (!mounted || epoch != _epoch) return;
    final pos = _pos;
    if (pos != null && pos.hasPixels) {
      // Stops any fling, then sets the offset silently so the next layout
      // already sees the new content at the new offset.
      pos.jumpTo(pos.pixels);
      pos.correctPixels(
        pos.hasViewportDimension ? -pos.viewportDimension * fraction : 0,
      );
    }
    setState(() {
      _blocks.clear();
      for (var b = lo; b <= hi; b++) {
        _blocks[b] = loaded[b - lo];
      }
      _loBlock = lo;
      _hiBlock = hi;
      _anchor = target;
      _rebuildItems();
    });
    _count('hjump');
    _count('hblk', hi - lo + 1);
    _log(
      'jump row=$target blocks=$lo-$hi load=${sw.elapsedMilliseconds}ms '
      'win=$_windowRows',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_firstPainted) {
        _firstPainted = true;
        final ms = _open.elapsedMilliseconds;
        _log('first rows painted ${widget.channel} in ${ms}ms');
        // After the first paint, so the activity scan never delays it.
        Future<void>(_buildRail);
      }
      final p = _pos;
      if (p != null && p.hasContentDimensions) {
        final clamped = p.pixels.clamp(p.minScrollExtent, p.maxScrollExtent);
        if (clamped != p.pixels) p.jumpTo(clamped);
      }
      _scheduleMaintain();
    });
  }

  /// Decodes block [b] with its markers, or takes the one a rail drag already
  /// started. The first row's predecessor time comes from the archive; a real
  /// block stores it in its header.
  Future<_Block> _fetch(int b) => _prefetched.remove(b) ?? _decode(b);

  Future<_Block> _decode(int b) async {
    final rows = await FakeHistory.loadBlock(widget.channel, b);
    final first = b * _bs;
    DateTime? prev = first == 0
        ? null
        : FakeHistory.timeOf(widget.channel, first - 1);
    final markers = <int, List<HistoryMarker>>{};
    for (var i = 0; i < rows.length; i++) {
      final time = rows[i].timestamp;
      final m = markersBefore(
        prev: prev,
        time: time,
        now: FakeHistory.now,
        streams: _streams,
      );
      if (m.isNotEmpty) markers[first + i] = m;
      prev = time;
    }
    return _Block(rows, markers);
  }

  /// Starts decoding the block a rail drag would land in.
  void _prefetch(int block) {
    if (block == _lastPrefetch) return;
    _lastPrefetch = block;
    if (_blocks.containsKey(block) || _prefetched.containsKey(block)) return;
    _prefetched[block] = _decode(block);
    while (_prefetched.length > _prefetchKeep) {
      _prefetched.remove(_prefetched.keys.first);
    }
  }

  /// Rebuilds both item lists from the loaded blocks and the anchor.
  void _rebuildItems() {
    final newer = <_Item>[];
    for (var r = _anchor; r < _hiRow; r++) {
      final ms = _markersOf(r);
      for (var k = 0; k < ms.length; k++) {
        newer.add(_Item(r, ms[k], k == 0));
      }
      newer.add(_Item(r, null, ms.isEmpty));
    }
    final older = <_Item>[];
    for (var r = _anchor - 1; r >= _loRow; r--) {
      older.add(_Item(r, null, true));
      final ms = _markersOf(r);
      for (var k = ms.length - 1; k >= 0; k--) {
        older.add(_Item(r, ms[k], false));
      }
    }
    _newerItems = newer;
    _olderItems = older;
  }

  List<HistoryMarker> _markersOf(int row) =>
      _blocks[row ~/ _bs]?.markers[row] ?? const [];

  void _jumpDaysAgo(int days) {
    final t = DateTime.now().subtract(Duration(days: days));
    _jumpToRow(FakeHistory.rowAtTime(widget.channel, t), fraction: 0.5);
  }

  // ---- Maintenance ---------------------------------------------------------

  void _scheduleMaintain() {
    if (_maintainScheduled) return;
    _maintainScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maintainScheduled = false;
      if (mounted) _maintain();
    });
  }

  /// Runs after layout: loads toward the nearer edge, then re-anchors.
  void _maintain() {
    final pos = _pos;
    if (pos == null || !pos.hasPixels || !pos.hasContentDimensions) return;
    if (_hiBlock < _loBlock) return;
    if (_scrolled) {
      _scrolled = false;
      _updateRail(pos);
    }
    final ahead = pos.viewportDimension * 4;
    if (pos.maxScrollExtent - pos.pixels < ahead && _loBlock > 0) {
      _load(_loBlock - 1);
    }
    if (pos.pixels - pos.minScrollExtent < ahead && _hiBlock < _lastBlock) {
      _load(_hiBlock + 1);
    }
    _maybeReanchor(pos);
  }

  Future<void> _load(int block) async {
    if (_blocks.containsKey(block) || !_inFlight.add(block)) return;
    final epoch = _epoch;
    final loaded = await _fetch(block);
    _inFlight.remove(block);
    if (!mounted || epoch != _epoch) return;
    // The window moved or trimmed while loading; only adjacent blocks attach.
    final adjacent = block == _loBlock - 1 || block == _hiBlock + 1;
    if (!adjacent) return;
    setState(() {
      _blocks[block] = loaded;
      if (block < _loBlock) _loBlock = block;
      if (block > _hiBlock) _hiBlock = block;
      _trim();
      _rebuildItems();
    });
    _count('hblk');
    _scheduleMaintain();
  }

  /// Drops far-end blocks while the window exceeds the cap. Only blocks fully
  /// beyond the anchor go, and only when the viewport is clear of them.
  void _trim() {
    final v = _viewportRow();
    while (_windowRows > _cap) {
      final dropOlder = v - _loRow >= _hiRow - v;
      if (dropOlder) {
        if (v - _loRow < _keepNear + _bs || (_loBlock + 1) * _bs > _anchor) {
          return;
        }
        _blocks.remove(_loBlock++);
      } else {
        if (_hiRow - v < _keepNear + _bs || _hiBlock * _bs < _anchor) return;
        _blocks.remove(_hiBlock--);
      }
      _count('hdrop');
    }
  }

  /// Row at the viewport's bottom edge, from the last layout; the anchor when
  /// nothing is built.
  int _viewportRow() {
    final pos = _pos;
    if (pos == null || !pos.hasPixels) return _anchor;
    final p = pos.pixels;
    final older = p > 0;
    final sliver = _sliver(older ? _olderKey : _newerKey);
    final edge = older ? p : -p;
    for (
      RenderBox? c = sliver?.firstChild;
      c != null;
      c = sliver!.childAfter(c)
    ) {
      final pd = c.parentData! as SliverMultiBoxAdaptorParentData;
      final offset = pd.layoutOffset;
      final index = pd.index;
      if (offset == null || index == null) continue;
      final items = older ? _olderItems : _newerItems;
      if (offset + c.size.height > edge && index < items.length) {
        return items[index].row;
      }
    }
    return _anchor;
  }

  RenderSliverMultiBoxAdaptor? _sliver(GlobalKey key) {
    final ro = key.currentContext?.findRenderObject();
    return ro is RenderSliverMultiBoxAdaptor ? ro : null;
  }

  /// Moves the anchor to the first built item of the sliver the viewport is
  /// in that can begin a sliver, once it is far from the current anchor.
  void _maybeReanchor(ScrollPosition pos) {
    final older = pos.pixels > 0;
    final sliver = _sliver(older ? _olderKey : _newerKey);
    final items = older ? _olderItems : _newerItems;
    final first = sliver?.firstChild;
    if (first == null) return;
    final firstIndex =
        (first.parentData! as SliverMultiBoxAdaptorParentData).index;
    if (firstIndex == null || firstIndex < _reanchorRows) return;
    // Markers cannot start a sliver: the boundary sits between whole row
    // groups, so skip ahead to the first group start.
    RenderBox? child = first;
    SliverMultiBoxAdaptorParentData? pd;
    while (child != null) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      final i = data.index;
      if (i != null && i < items.length && items[i].start) {
        pd = data;
        break;
      }
      child = sliver!.childAfter(child);
    }
    final index = pd?.index;
    final offset = pd?.layoutOffset;
    if (index == null || offset == null) return;
    final target = items[index];
    // Older: the first row's near edge becomes the boundary, rows between
    // move to the newer sliver, so pixels drop by that offset. Newer is the
    // mirror image.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final activity = pos.activity;
    final flinging = activity is BallisticScrollActivity;
    final velocity = flinging ? activity.velocity : 0.0;
    var correction = older ? -offset : offset;
    if (flinging && pos is ScrollPositionWithSingleContext) {
      // The fling's simulation holds absolute pixels; restart it from the
      // corrected position at the same speed so the fling carries on. The
      // new animation spends its first frame at t=0, so the correction also
      // carries one frame of travel to avoid a one-frame stall.
      final hz = View.of(context).display.refreshRate;
      correction += velocity / (hz > 0 ? hz : 60);
      pos.correctBy(correction);
      pos.goBallistic(velocity);
    } else {
      pos.correctBy(correction);
    }
    setState(() {
      _anchor = older ? target.row + 1 : target.row;
      _trim();
      _rebuildItems();
    });
    _count('hanc');
    _log(
      're-anchor to row $_anchor shift=${offset.round()}px win=$_windowRows',
    );
    _scheduleMaintain();
  }

  // ---- Rail ----------------------------------------------------------------

  /// Builds (once per channel) the activity-weighted rail model.
  void _buildRail() {
    if (!mounted || _railReady.value != null) return;
    final ch = widget.channel;
    _railReady.value = _rails[ch] ??= ActivityRail(
      from: FakeHistory.startOf(ch),
      to: FakeHistory.now,
      bucket: _railBucket,
      counts: FakeHistory.activity.counts(
        ch,
        FakeHistory.startOf(ch),
        FakeHistory.now,
        _railBucket,
      ),
      streams: _streams,
    );
  }

  /// Follows the list on scroll: shows the rail after a long scroll up or a
  /// hard fling and keeps the thumb on the viewport's time while visible.
  void _updateRail(ScrollPosition pos) {
    _peek.value = false;
    final rail = _railReady.value;
    if (rail == null || _railDragging) return;
    final row = _viewportRow();
    if (!_railVisible.value) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      final activity = pos.activity;
      final fling =
          activity is BallisticScrollActivity &&
          activity.velocity.abs() > _railFlingSpeed;
      final behind = _total - row;
      if (behind < (fling ? _railAfterRows ~/ 5 : _railAfterRows)) return;
      _railVisible.value = true;
    }
    _thumb.value = rail.positionOf(FakeHistory.timeOf(widget.channel, row));
    _bumpIdle();
  }

  /// Extends the fade deadline. One timer re-arms itself, so scroll frames
  /// allocate none.
  void _bumpIdle() {
    _idleDeadline = _clock.elapsedMilliseconds + _railIdleMs;
    _idleTimer ??= Timer(const Duration(milliseconds: _railIdleMs), _idleCheck);
  }

  void _idleCheck() {
    _idleTimer = null;
    if (!mounted) return;
    final left = _idleDeadline - _clock.elapsedMilliseconds;
    if (_railDragging) {
      _bumpIdle();
    } else if (left > 0) {
      _idleTimer = Timer(Duration(milliseconds: left), _idleCheck);
    } else {
      _railVisible.value = false;
      _peek.value = false;
    }
  }

  int _rowAtRail(double pos) =>
      FakeHistory.rowAtTime(widget.channel, _railReady.value!.timeAt(pos));

  void _onRailDragStart() {
    _railDragging = true;
    _peek.value = false;
    _bumpIdle();
  }

  void _onRailDrag(double pos) {
    _bumpIdle();
    final row = _rowAtRail(pos);
    _prefetch((row >= _total ? _total - 1 : row) ~/ _bs);
  }

  void _onRailDragEnd(double pos) {
    _railDragging = false;
    _lastPrefetch = -1;
    _bumpIdle();
    _jumpToRow(_rowAtRail(pos), fraction: 0.5);
  }

  /// Shows the rail with its bubble at [time], for a tapped day marker.
  void _peekRail(DateTime time) {
    final rail = _railReady.value;
    if (rail == null) return;
    _thumb.value = rail.positionOf(time);
    _peek.value = true;
    _railVisible.value = true;
    _bumpIdle();
  }

  void _onMarkerTap(HistoryMarker m) {
    final stream = m.stream;
    if (stream != null) {
      _jumpToRow(
        FakeHistory.rowAtTime(widget.channel, stream.start),
        fraction: 0.5,
      );
    } else {
      _peekRail(m.time);
    }
  }

  // ---- Build ---------------------------------------------------------------

  TwitchMessage? _msg(int row) {
    final block = _blocks[row ~/ _bs];
    return block?.rows[row % _bs];
  }

  Widget _item(BuildContext context, List<_Item> items, int j) {
    final item = items[j];
    final marker = item.marker;
    return marker == null
        ? _row(context, item.row)
        : _markerRow(context, marker);
  }

  Widget _markerRow(BuildContext context, HistoryMarker m) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    if (_fmtLocale != locale) {
      _fmtLocale = locale;
      _dayFmt = DateFormat.MMMMEEEEd(locale);
      _shortDayFmt = DateFormat.MMMd(locale);
    }
    final stream = m.stream;
    final String text;
    final Color color;
    switch (m.kind) {
      case HistoryMarkerKind.streamStart:
        text = l10n.historyStreamStarted(stream!.title, stream.game);
        color = streamAccent;
      case HistoryMarkerKind.streamEnd:
        text = l10n.historyStreamEnded(
          formatStreamLength(stream!.end.difference(stream.start)),
        );
        color = streamAccent;
      case HistoryMarkerKind.day:
        text = _dayFmt!.format(dayFromNumber(m.firstDay));
        color = scheme.secondary;
      case HistoryMarkerKind.emptyStretch:
        final from = _shortDayFmt!.format(dayFromNumber(m.firstDay));
        text = l10n.historyNothingRecorded(
          m.firstDay == m.lastDay
              ? from
              : l10n.historyDateRange(
                  from,
                  _shortDayFmt!.format(dayFromNumber(m.lastDay)),
                ),
        );
        color = scheme.onSurfaceVariant;
    }
    return KeyedSubtree(
      key: ValueKey<String>(m.key),
      child: InkWell(
        onTap: () => _onMarkerTap(m),
        child: Ink(
          // Stream rows tint like the live announcement-style block.
          color: color == streamAccent
              ? streamAccent.withValues(alpha: 0.15)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14 * widget.textScale,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int row) {
    final msg = _msg(row);
    if (msg == null) return const SizedBox.shrink();
    final b = widget.messageBuilder;
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    return KeyedSubtree(
      key: ValueKey<String>(msg.messageId!),
      child: RepaintBoundary(
        child: ChatMessageTile(
          message: msg,
          channel: widget.channel,
          surface: Theme.of(context).scaffoldBackgroundColor,
          textScale: widget.textScale,
          showTimestamp: widget.showTimestamp,
          timestampFormat: widget.timestampFormat,
          lineSeparator: widget.lineSeparator,
          isAlternateBackground: row.isEven,
          buildBadgeSpans: b.buildBadgeSpans,
          buildMessageSpans: b.buildMessageSpans,
          bodyIsCached: b.bodyIsCached,
          replyIndicator: msg.replyToUser == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.reply, size: 16, color: variant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Replying to ${msg.replyToUser}: ${msg.replyToText}',
                          style: TextStyle(fontSize: 12, color: variant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = GlassChromeScope.maybeOf(context);
    final bottom =
        ((scope?.bottomClearance ?? 0) > 0.5
            ? scope!.bottomClearance
            : kOpaqueComposerGap) +
        (scope?.listExtra ?? 0);
    _status = 'win $_windowRows  blocks $_loBlock-$_hiBlock  anchor $_anchor';
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: CustomScrollView(
            controller: _controller,
            reverse: true,
            center: _olderKey,
            slivers: [
              SliverList(
                key: _newerKey,
                delegate: SliverChildBuilderDelegate(
                  (ctx, j) => _item(ctx, _newerItems, j),
                  childCount: _newerItems.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: false,
                  addSemanticIndexes: false,
                ),
              ),
              SliverList(
                key: _olderKey,
                delegate: SliverChildBuilderDelegate(
                  (ctx, j) => _item(ctx, _olderItems, j),
                  childCount: _olderItems.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: false,
                  addSemanticIndexes: false,
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: widget.topPadding)),
            ],
          ),
        ),
        Positioned(
          top: widget.topPadding + 56,
          right: 0,
          bottom: bottom + 8,
          child: ValueListenableBuilder<ActivityRail?>(
            valueListenable: _railReady,
            builder: (context, rail, _) => rail == null
                ? const SizedBox.shrink()
                : HistoryScrubber(
                    rail: rail,
                    thumb: _thumb,
                    visible: _railVisible,
                    peek: _peek,
                    onDragStart: _onRailDragStart,
                    onDrag: _onRailDrag,
                    onDragEnd: _onRailDragEnd,
                  ),
          ),
        ),
        Positioned(
          top: widget.topPadding + 4,
          left: 4,
          right: 4,
          child: _controls(context),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(String label, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            button('newest', () => _jumpToRow(_total)),
            for (final d in const [1, 3, 7, 14, 29])
              button('${d}d', () => _jumpDaysAgo(d)),
          ],
        ),
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          child: Text(
            '${widget.channel} (fake)  $_status',
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ],
    );
  }
}
