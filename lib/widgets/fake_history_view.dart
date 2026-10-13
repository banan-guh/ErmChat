import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../models/twitch_message.dart';
import '../util/fake_history.dart';
import '../util/log.dart';
import '../util/perf_probe.dart';
import '../util/timestamp_formatter.dart';
import 'chat_message_tile.dart';
import 'glass_chrome.dart';
import 'message_builder.dart';

/// Prototype of the windowed history list over [FakeHistory] data, shown for
/// the fake channels when `ERMCHAT_FAKE_HISTORY` is on.
///
/// One reversed `CustomScrollView` with a `center` sliver. The center sliver
/// holds rows older than [_anchor] (item j is row `_anchor - 1 - j`), the
/// sliver before it holds newer rows (item j is row `_anchor + j`). Blocks
/// load at the edge being approached and drop from the far edge. When the
/// viewport drifts [_reanchorRows] rows from the anchor, the anchor moves to
/// the viewport and `correctBy` keeps the content still, so the far ends can
/// trim without moving anything on screen.
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

class _FakeHistoryViewState extends State<FakeHistoryView> {
  static const int _cap = 3000;
  static const int _bs = FakeHistory.blockSize;

  /// Rows between viewport and anchor that trigger a re-anchor.
  static const int _reanchorRows = 800;

  /// Rows kept on each side of the viewport when trimming.
  static const int _keepNear = 500;

  static final Map<String, int> _counters = {};
  static _FakeHistoryViewState? _active;

  final ScrollController _controller = ScrollController();
  final GlobalKey _olderKey = GlobalKey();
  final GlobalKey _newerKey = GlobalKey();
  final Map<int, List<TwitchMessage>> _blocks = {};
  final Set<int> _inFlight = {};
  final Stopwatch _open = Stopwatch()..start();

  late final int _total = FakeHistory.rowCount(widget.channel);
  late final int _lastBlock = FakeHistory.blockCount(widget.channel) - 1;

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
    _controller.addListener(_scheduleMaintain);
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
    _controller.dispose();
    super.dispose();
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
      for (var b = lo; b <= hi; b++) FakeHistory.loadBlock(widget.channel, b),
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
      }
      final p = _pos;
      if (p != null && p.hasContentDimensions) {
        final clamped = p.pixels.clamp(p.minScrollExtent, p.maxScrollExtent);
        if (clamped != p.pixels) p.jumpTo(clamped);
      }
      _scheduleMaintain();
    });
  }

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
    final rows = await FakeHistory.loadBlock(widget.channel, block);
    _inFlight.remove(block);
    if (!mounted || epoch != _epoch) return;
    // The window moved or trimmed while loading; only adjacent blocks attach.
    final adjacent = block == _loBlock - 1 || block == _hiBlock + 1;
    if (!adjacent) return;
    setState(() {
      _blocks[block] = rows;
      if (block < _loBlock) _loBlock = block;
      if (block > _hiBlock) _hiBlock = block;
      _trim();
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
      if (offset + c.size.height > edge) {
        return older ? _anchor - 1 - index : _anchor + index;
      }
    }
    return _anchor;
  }

  RenderSliverMultiBoxAdaptor? _sliver(GlobalKey key) {
    final ro = key.currentContext?.findRenderObject();
    return ro is RenderSliverMultiBoxAdaptor ? ro : null;
  }

  /// Moves the anchor to the first built row of the sliver the viewport is in,
  /// once that row is far from the current anchor.
  void _maybeReanchor(ScrollPosition pos) {
    final older = pos.pixels > 0;
    final sliver = _sliver(older ? _olderKey : _newerKey);
    final first = sliver?.firstChild;
    if (first == null) return;
    final pd = first.parentData! as SliverMultiBoxAdaptorParentData;
    final index = pd.index;
    final offset = pd.layoutOffset;
    if (index == null || offset == null || index < _reanchorRows) return;
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
      _anchor += older ? -index : index;
      _trim();
    });
    _count('hanc');
    _log(
      're-anchor to row $_anchor shift=${offset.round()}px win=$_windowRows',
    );
    _scheduleMaintain();
  }

  // ---- Build ---------------------------------------------------------------

  TwitchMessage? _msg(int row) {
    final block = _blocks[row ~/ _bs];
    return block == null ? null : block[row % _bs];
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
    final older = (_anchor - _loRow).clamp(0, _total);
    final newer = (_hiRow - _anchor).clamp(0, _total);
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
                  (ctx, j) => _row(ctx, _anchor + j),
                  childCount: newer,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: false,
                  addSemanticIndexes: false,
                ),
              ),
              SliverList(
                key: _olderKey,
                delegate: SliverChildBuilderDelegate(
                  (ctx, j) => _row(ctx, _anchor - 1 - j),
                  childCount: older,
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
