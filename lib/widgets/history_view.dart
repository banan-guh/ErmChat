import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

import '../color_utils.dart' show streamAccent;
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../sheets/history_marker_sheet.dart';
import '../util/history_timeline.dart';
import '../util/history_window.dart';
import '../util/log.dart';
import '../util/perf_probe.dart';
import 'chat_message_tile.dart';
import 'chat_rows.dart';
import 'chat_widget_cutout.dart' show ChatWidgetMinimizedBar;
import 'chrome_menu_button.dart' show kChromeMenuMargin;
import 'glass_chrome.dart';
import 'history_scrubber.dart';

/// Windowed history list over a [HistorySource].
///
/// One reversed `CustomScrollView` with a `center` sliver. The center sliver
/// holds items older than [_anchor], the sliver before it holds newer items.
/// An item is a row or a derived marker (stream start/end, day, empty
/// stretch) that sits before its row in time. Rows load at the edge being
/// approached and drop from the far edge ([HistoryWindow]). When the viewport
/// drifts [_reanchorItems] items from the anchor, the anchor moves to the
/// viewport and `correctBy` keeps the content still, so the far ends can trim
/// without moving anything on screen. A time rail ([HistoryScrubber]) fades
/// in after a long scroll and jumps through [_jumpTo].
///
/// Live rows continue the source at the newest end. Arrivals append below
/// the anchor, so nothing on screen moves; while following, the physics pins
/// the list to the newest row in the same layout. Any other buffer change
/// replaces the live tail, and a hold on the row at the viewport's bottom
/// edge keeps that row still.
class HistoryView extends StatefulWidget {
  const HistoryView({
    super.key,
    required this.channel,
    required this.source,
    required this.rows,
    this.textScale = 1.0,
    this.topPadding = 0,
    this.debugControls = false,
    this.live,
    this.liveVersion,
    this.emotesVersion,
    this.tileCache,
    this.atBottomNotifier,
    this.onScrollActivity,
    this.scrollFabHeroTag,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.emptyText,
  });

  final String channel;
  final HistorySource source;

  /// Builds message rows the way the chat lists do.
  final ChatRows rows;

  /// Chat font scale; the system text scale multiplies in.
  final double textScale;

  /// Clearance above the oldest row, below a floating header.
  final double topPadding;

  /// Jump buttons and window stats over the list, for the prototype channels.
  final bool debugControls;

  /// The live buffer, newest first, continuing past the source's newest row.
  /// Null when the source has no live chat.
  final List<TwitchMessage> Function()? live;

  /// Bumps whenever [live] changes.
  final Listenable? liveVersion;

  /// Bumps when an emote catalog lands, so source rows parsed before it
  /// re-parse. Live rows heal through their buffer.
  final Listenable? emotesVersion;

  /// Tile caches by channel, then message id; the owner evicts edited rows
  /// and may drop a channel's map. Null builds rows fresh.
  final Map<String, Map<String?, Widget>>? tileCache;

  /// True while the newest row is in view. Set true from outside (a tab tap)
  /// to jump to the newest row.
  final ValueNotifier<bool>? atBottomNotifier;

  /// Called with [channel] whenever [atBottomNotifier] flips.
  final void Function(String channel)? onScrollActivity;

  /// Hero tag for the scroll-down FAB. Defaults to [channel]-keyed.
  final String? scrollFabHeroTag;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Shown when there is nothing to show; null shows nothing.
  final String? emptyText;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

/// One list item: a row at [pos], or a marker before it. [start] is true for
/// the item a sliver may begin at when the anchor moves: the first of a row's
/// group in time order (newer sliver) or the row itself (older sliver).
class _Item {
  const _Item(this.pos, this.marker, this.start);

  final int pos;
  final HistoryMarker? marker;
  final bool start;
}

/// Lets the view correct the offset in the layout that applies new content:
/// pinned to the newest row while following, or holding a row in place.
mixin _HoldPhysicsMixin on ScrollPhysics {
  double? Function(ScrollMetrics) get resolve;

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) =>
      resolve(newPosition) ??
      super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity,
      );
}

class _HoldClampingPhysics extends ClampingScrollPhysics
    with _HoldPhysicsMixin {
  const _HoldClampingPhysics({super.parent, required this.resolve});

  @override
  final double? Function(ScrollMetrics) resolve;

  @override
  _HoldClampingPhysics applyTo(ScrollPhysics? ancestor) =>
      _HoldClampingPhysics(parent: buildParent(ancestor), resolve: resolve);
}

class _HoldBouncingPhysics extends BouncingScrollPhysics
    with _HoldPhysicsMixin {
  const _HoldBouncingPhysics({super.parent, required this.resolve});

  @override
  final double? Function(ScrollMetrics) resolve;

  @override
  _HoldBouncingPhysics applyTo(ScrollPhysics? ancestor) =>
      _HoldBouncingPhysics(parent: buildParent(ancestor), resolve: resolve);
}

/// Rows a re-anchor shifted within one sliver: each row's new index by its
/// key, and the layout offset at each new index. Live for the one rebuild
/// and layout that apply the re-anchor.
class _Moves {
  final Map<String, int> indexOf = {};
  final Map<int, double> offsets = {};

  int? find(Key key) => key is ValueKey<String> ? indexOf[key.value] : null;

  void clear() {
    indexOf.clear();
    offsets.clear();
  }
}

/// A [SliverList] that restores the offsets of rows [_Moves] shifted. A
/// moved child otherwise keeps no offset unless its new slot held a child
/// last layout, and the sliver drops it or fails hit testing on it
/// (flutter#153922).
class _MovingSliverList extends SliverList {
  const _MovingSliverList({
    super.key,
    required super.delegate,
    required this.moves,
  });

  final _Moves moves;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderMovingSliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
        moves: moves,
      );
}

class _RenderMovingSliverList extends RenderSliverList {
  _RenderMovingSliverList({required super.childManager, required this.moves});

  final _Moves moves;

  @override
  void performLayout() {
    final offsets = moves.offsets;
    if (offsets.isNotEmpty) {
      for (RenderBox? c = firstChild; c != null; c = childAfter(c)) {
        final d = c.parentData! as SliverMultiBoxAdaptorParentData;
        final o = offsets[d.index];
        if (o != null) d.layoutOffset = o;
      }
      offsets.clear();
    }
    super.performLayout();
  }
}

class _HistoryViewState extends State<HistoryView> {
  static const int _cap = 3000;

  /// Rows trimmed at once from a far end.
  static const int _trimChunk = 256;

  /// Items between viewport and anchor that trigger a re-anchor.
  static const int _reanchorItems = 800;

  /// Items the older sliver keeps so it always spans more than a viewport. The
  /// viewport floors its scroll max at the anchor, so a shorter older sliver
  /// would let the list scroll past the oldest row into empty space.
  static const int _minOlderItems = 80;

  /// Rows kept on each side of the viewport when trimming.
  static const int _keepNear = 500;

  /// The rail appears once the viewport is this many rows or this much time
  /// behind newest, whichever comes first.
  static const int _railAfterRows = 100;
  static const Duration _railAfterAge = Duration(hours: 1);

  static const int _railIdleMs = 1500;

  /// Rail positions this close to an end jump to that end of the list.
  static const double _railEndSnap = 0.01;

  /// The scroll-down button's height, a standard FAB.
  static const double _fabSize = 56;

  static final Map<String, int> _counters = {};
  static _HistoryViewState? _active;

  final ScrollController _controller = ScrollController();
  final GlobalKey _olderKey = GlobalKey();
  final GlobalKey _newerKey = GlobalKey();
  final _Moves _olderMoves = _Moves();
  final _Moves _newerMoves = _Moves();
  late final HistoryWindow _window = HistoryWindow(now: widget.source.now);
  final Stopwatch _open = Stopwatch()..start();
  List<_Item> _newerItems = const [];
  List<_Item> _olderItems = const [];
  bool _loadingOlder = false;
  bool _loadingNewer = false;

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
  bool _railBuilding = false;
  bool _scrolled = false;
  ({DateTime time, Future<List<TwitchMessage>> rows})? _prefetched;
  bool _prefetching = false;
  String? _fmtLocale;
  DateFormat? _dayFmt;
  DateFormat? _shortDayFmt;

  /// Position at the boundary: older rows sit above it, this row and newer
  /// below.
  int _anchor = 0;

  /// The window ends in the live buffer; rows from [_liveStart] on mirror it.
  /// Rows before [_liveStart] left the buffer but stay until trimmed.
  bool _liveAttached = false;
  int _liveStart = 0;

  /// Sticks to the newest row as rows arrive. Only a user drag clears it;
  /// coming to rest on the newest row sets it again.
  bool _follow = true;

  /// Row to keep still through the next layout: its key, the scroll
  /// coordinate of its bottom edge before the change, and its height. Sizes
  /// cannot be read during the layout that resolves the hold, so the height
  /// comes along.
  ({String key, double coord, double height})? _hold;
  static const double _followEps = 0.5;

  /// Tile cache bound, like [ChatView]'s.
  static const int _maxCachedTiles = 300;

  /// Live row gates, re-checked against the viewport after each layout.
  final Set<RowGateState> _gates = {};
  bool _gateSyncScheduled = false;

  /// Mirror of what this view last wrote to [HistoryView.atBottomNotifier],
  /// so an outside write reads as a request to jump.
  bool _atBottom = true;
  double _systemScale = 1;

  /// The first window is in, so an empty one means nothing to show.
  bool _loaded = false;
  int _epoch = 0;
  bool _maintainScheduled = false;
  bool _firstPainted = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _active = this;
    PerfProbe.counters(_counters);
    PerfProbe.gauge('hwin', () => _active?._window.length ?? 0);
    if (PerfProbe.enabled) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    }
    widget.liveVersion?.addListener(_onLive);
    widget.emotesVersion?.addListener(_onEmotes);
    widget.atBottomNotifier?.addListener(_onAtBottomRequest);
    _unwatchClears = widget.source.watchClears(_onClear);
    _unwatchStreams = widget.source.watchStreams(_loadStreams);
  }

  void Function()? _unwatchClears;
  void Function()? _unwatchStreams;

  @override
  void deactivate() {
    // Ancestor lookups still work here, unlike in dispose.
    _saveReading();
    super.deactivate();
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _start();
    }
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    if (scale != _systemScale) {
      _systemScale = scale;
      // Pixel-sized tiles would otherwise survive the scale change.
      widget.tileCache?.clear();
    }
  }

  @override
  void didUpdateWidget(HistoryView old) {
    super.didUpdateWidget(old);
    if (old.liveVersion != widget.liveVersion) {
      old.liveVersion?.removeListener(_onLive);
      widget.liveVersion?.addListener(_onLive);
      _onLive();
    }
    if (old.emotesVersion != widget.emotesVersion) {
      old.emotesVersion?.removeListener(_onEmotes);
      widget.emotesVersion?.addListener(_onEmotes);
    }
    if (old.atBottomNotifier != widget.atBottomNotifier) {
      old.atBottomNotifier?.removeListener(_onAtBottomRequest);
      widget.atBottomNotifier?.addListener(_onAtBottomRequest);
    }
  }

  /// Opens at the saved reading position or the newest row. Streams load
  /// alongside and mark the rows once in, so they never hold up the rows.
  void _start() {
    final saved = _readSaved();
    if (saved == null) {
      _jumpTo(null);
    } else {
      _jumpTo(saved.time, offset: saved.offset);
    }
    _loadStreams();
  }

  /// Reads the broadcasts and re-marks the rows; again whenever one starts,
  /// ends or reopens, so a page never keeps a stale end.
  void _loadStreams() {
    widget.source.streams().then((streams) {
      if (!mounted || (streams.isEmpty && _window.streams.isEmpty)) return;
      setState(() {
        _window.setStreams(streams);
        _rebuildItems();
      });
    });
  }

  // ---- Reading position ----------------------------------------------------

  /// Where the reader was when the page unmounted: the row at the viewport's
  /// bottom edge and how far its top sat above that edge. Nothing is saved
  /// while following, so the page comes back at the newest row.
  void _saveReading() {
    final bucket = PageStorage.maybeOf(context);
    if (bucket == null) return;
    ({DateTime time, double offset})? reading;
    final pos = _pos;
    if (!_follow && pos != null && pos.hasPixels) {
      final row = _rowAtEdge();
      if (row != null) {
        reading = (time: row.row.timestamp, offset: row.top - pos.pixels);
      }
    }
    bucket.writeState(context, reading, identifier: _storageId);
  }

  ({DateTime time, double offset})? _readSaved() {
    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageId);
    return saved is ({DateTime time, double offset}) ? saved : null;
  }

  String get _storageId => 'history:${widget.channel}';

  // ---- Bottom --------------------------------------------------------------

  /// Mirrors the newest-row-in-view state to [HistoryView.atBottomNotifier].
  void _setAtBottom(bool value) {
    final n = widget.atBottomNotifier;
    // A fresh view may inherit a stale false from the shared notifier.
    if (value == _atBottom && (n == null || n.value == value)) return;
    _atBottom = value;
    if (n != null && n.value != value) {
      n.value = value;
      widget.onScrollActivity?.call(widget.channel);
    }
  }

  /// Following counts as at the bottom, so the button never flashes while a
  /// rejoin or layout is still bringing the newest row in.
  void _syncAtBottom(ScrollMetrics m) => _setAtBottom(
    _follow || (_window.atNewest && m.pixels <= m.minScrollExtent + _followEps),
  );

  /// Puts a following list back on the newest row when a layout left it
  /// short of the end.
  void _snapToNewest(ScrollPosition p) {
    if (_follow &&
        _window.atNewest &&
        p.pixels > p.minScrollExtent + _followEps) {
      p.jumpTo(p.minScrollExtent);
    }
  }

  /// An outside write of true (a tab tap) asks for the newest row.
  void _onAtBottomRequest() {
    final n = widget.atBottomNotifier;
    if (n != null && n.value && !_atBottom) _jumpToNewest();
  }

  /// Back to the newest row: a scroll when it is already near, otherwise a
  /// fresh window.
  void _jumpToNewest() {
    _follow = true;
    _atBottom = true;
    widget.atBottomNotifier?.value = true;
    widget.onScrollActivity?.call(widget.channel);
    final pos = _pos;
    if (_window.atNewest &&
        pos != null &&
        pos.hasContentDimensions &&
        pos.pixels - pos.minScrollExtent < pos.viewportDimension * 4) {
      pos.jumpTo(pos.minScrollExtent);
      _settleAtEnd(oldest: false);
      return;
    }
    _jumpTo(null);
  }

  /// Keeps a jump to either end on it for a few frames. Extents past the
  /// built rows are estimates until those rows lay out, so the first jump can
  /// fall short or overshoot. A new jump or a touch ends it.
  void _settleAtEnd({required bool oldest, int tries = 4}) {
    final epoch = _epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = _pos;
      if (!mounted || epoch != _epoch || p == null) return;
      if (!p.hasContentDimensions || p.isScrollingNotifier.value) return;
      if (!oldest && !_follow) return;
      final end = oldest ? p.maxScrollExtent : p.minScrollExtent;
      if ((p.pixels - end).abs() <= _followEps) return;
      p.jumpTo(end);
      if (tries > 1) _settleAtEnd(oldest: oldest, tries: tries - 1);
    });
  }

  // ---- Gates ---------------------------------------------------------------

  void _scheduleGateSync() {
    if (_gateSyncScheduled) return;
    _gateSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gateSyncScheduled = false;
      final pos = _pos;
      if (mounted && pos != null) syncRowGates(_gates, pos);
    });
  }

  @override
  void dispose() {
    widget.liveVersion?.removeListener(_onLive);
    widget.emotesVersion?.removeListener(_onEmotes);
    widget.atBottomNotifier?.removeListener(_onAtBottomRequest);
    _unwatchClears?.call();
    _unwatchStreams?.call();
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

  /// Replaces the window with rows around [time] (the newest rows when null)
  /// and puts the boundary there: older rows above, the first row at or after
  /// [time] and newer below, [fraction] of the viewport up from the bottom.
  /// Awaits the rows first so the old content stays up until the new content
  /// is ready.
  Future<void> _jumpTo(
    DateTime? time, {
    double fraction = 0,
    double offset = 0,
    Future<List<TwitchMessage>>? rows,
  }) async {
    final epoch = ++_epoch;
    _loadingOlder = false;
    _loadingNewer = false;
    _follow = time == null;
    _hold = null;
    final sw = Stopwatch()..start();
    final source = widget.source;
    // With a live buffer the newest rows are on hand; history prepends as it
    // reads, so the archive never holds up live chat.
    final liveFirst = time == null && rows == null && widget.live != null;
    final loaded = liveFirst
        ? const <TwitchMessage>[]
        : await (rows ??
              (time == null ? source.newest() : source.around(time)));
    if (!mounted || epoch != _epoch) return;
    // A target near the oldest row needs the rows above it before the anchor
    // can sit there; otherwise the older sliver could not span the viewport.
    var olderRows = const <TwitchMessage>[];
    if (loaded.isNotEmpty && time != null) {
      final before = loaded.where((m) => m.timestamp.isBefore(time)).length;
      if (before < _minOlderItems) {
        olderRows = await source.older(loaded.first.timestamp);
        if (!mounted || epoch != _epoch) return;
      }
    }
    final pos = _pos;
    if (pos != null && pos.hasPixels) {
      // Stops any fling, then sets the offset silently so the next layout
      // already sees the new content at the new offset.
      pos.jumpTo(pos.pixels);
      pos.correctPixels(
        -offset -
            (pos.hasViewportDimension ? pos.viewportDimension * fraction : 0),
      );
      // correctPixels notifies nothing and an unchanged window rebuilds no
      // child, so a jump to the current anchor would never lay out.
      _sliver(_olderKey)?.markNeedsLayout();
    }
    var pinOldest = false;
    setState(() {
      _loaded = true;
      _window.reset(loaded);
      if (olderRows.isNotEmpty || time != null) {
        if (_window.prepend(olderRows) == 0 && time != null) {
          final head = _window.positionAt(time) - _window.first;
          if (head < _minOlderItems) _window.markOldest();
        }
      }
      _liveAttached = false;
      if (time == null) _attachLive();
      final target = time == null ? _window.end : _window.positionAt(time);
      // At the oldest end the anchor moves newer so the older sliver stays
      // long enough; the list then rests on the oldest row.
      _anchor = _window.atOldest && target - _window.first < _minOlderItems
          ? (_window.first + _minOlderItems).clamp(_window.first, _window.end)
          : target;
      pinOldest = _anchor > target;
      _rebuildItems();
    });
    _count('hjump');
    _log(
      'jump ${time ?? 'newest'} rows=${_window.length} '
      'load=${sw.elapsedMilliseconds}ms',
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
        final clamped = pinOldest
            ? p.maxScrollExtent
            : p.pixels.clamp(p.minScrollExtent, p.maxScrollExtent);
        if (clamped != p.pixels) p.jumpTo(clamped);
        _snapToNewest(p);
        _syncAtBottom(p);
        if (pinOldest) _settleAtEnd(oldest: true);
        if (time == null) _settleAtEnd(oldest: false);
      }
      _scheduleMaintain();
    });
  }

  /// Adds items for positions [from] on to the newer sliver, after rows
  /// appended below an anchor at or before [from].
  void _appendItems(int from) {
    final w = _window;
    final newer = _newerItems;
    for (var p = from; p < w.end; p++) {
      final ms = w.markersAt(p);
      for (var k = 0; k < ms.length; k++) {
        newer.add(_Item(p, ms[k], k == 0));
      }
      newer.add(_Item(p, null, ms.isEmpty));
    }
  }

  /// Rebuilds both item lists from the window and the anchor.
  void _rebuildItems() {
    final w = _window;
    final newer = <_Item>[];
    for (var p = _anchor; p < w.end; p++) {
      final ms = w.markersAt(p);
      for (var k = 0; k < ms.length; k++) {
        newer.add(_Item(p, ms[k], k == 0));
      }
      newer.add(_Item(p, null, ms.isEmpty));
    }
    final older = <_Item>[];
    for (var p = _anchor - 1; p >= w.first; p--) {
      older.add(_Item(p, null, true));
      final ms = w.markersAt(p);
      for (var k = ms.length - 1; k >= 0; k--) {
        older.add(_Item(p, ms[k], false));
      }
    }
    _newerItems = newer;
    _olderItems = older;
  }

  void _jumpDaysAgo(int days) {
    final t = widget.source.now().subtract(Duration(days: days));
    _jumpTo(t, fraction: 0.5);
  }

  // ---- Live ----------------------------------------------------------------

  /// Ends the window in the live buffer. Call inside setState; the window
  /// counts as newest even without a live buffer.
  void _attachLive() {
    _window.atNewest = true;
    if (widget.live == null) return;
    _liveAttached = true;
    _liveStart = _window.end;
    _syncLive(attaching: true);
  }

  void _onLive() {
    if (!mounted || !_liveAttached) return;
    setState(() {
      _syncLive();
      // A reader scrolled up keeps a window, not every arrival: past the cap
      // the newest rows detach and read back from the source on the way down.
      final n = _window.length;
      if (!_follow && n > _cap) {
        _trim();
        if (_window.length != n) _rebuildItems();
      }
    });
    _scheduleMaintain();
    final pos = _pos;
    if (pos != null && pos.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = _pos;
        if (!mounted || p == null || !p.hasContentDimensions) return;
        _snapToNewest(p);
        _syncAtBottom(p);
      });
    }
  }

  /// Fades held rows a late delete covers. Runs after the moderation call
  /// returns, so buffer rows are the kernel's to mark and stay untouched
  /// here.
  void _onClear(HistoryClear clear) {
    scheduleMicrotask(() {
      if (!mounted) return;
      final w = _window;
      final cache = widget.tileCache?[widget.channel];
      var hit = false;
      for (var p = w.first; p < w.end; p++) {
        final m = w[p];
        if (m.isSystem ||
            m.deleted ||
            m.timestamp.isBefore(clear.from) ||
            m.timestamp.isAfter(clear.to) ||
            (clear.login != null && m.login != clear.login)) {
          continue;
        }
        m.deleted = true;
        cache?.remove(m.messageId);
        hit = true;
      }
      if (hit) setState(() {});
    });
  }

  /// Clears the tokens of source rows parsed while catalogs were landing, so
  /// their next build parses against the fuller catalog.
  void _onEmotes() {
    if (!mounted) return;
    final w = _window;
    final cache = widget.tileCache?[widget.channel];
    final end = _liveAttached && _liveStart < w.end ? _liveStart : w.end;
    var healed = false;
    for (var p = w.first; p < end; p++) {
      final m = w[p];
      if (!m.emotesPartial) continue;
      m.emotesPartial = false;
      m.emoteTokens = null;
      cache?.remove(m.messageId);
      healed = true;
    }
    if (healed) setState(() {});
  }

  /// Mirrors the live buffer into the window's tail. Arrivals append; any
  /// other change replaces the tail from the first row that differs, holding
  /// the row on screen. Call inside setState.
  void _syncLive({bool attaching = false}) {
    final rows = widget.live?.call();
    if (rows == null || rows.isEmpty) return;
    final w = _window;
    final oldest = rows[rows.length - 1];
    // The buffer only drops rows at its old end, so its oldest row sits at
    // or after the last sync's start.
    int? k;
    final start = _liveStart < w.first ? w.first : _liveStart;
    for (var p = start; p < w.end; p++) {
      if (identical(w[p], oldest)) {
        k = p;
        break;
      }
    }
    if (k == null) {
      // The buffer moved past every row synced before (the page sat
      // inactive): rows between may only be in the archive. Following
      // starts over at the newest rows; a reader detaches and scrolling
      // down reads them back.
      if (!attaching &&
          !w.isEmpty &&
          oldest.timestamp.isAfter(w[w.end - 1].timestamp)) {
        _liveAttached = false;
        w.atNewest = false;
        if (_follow) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _jumpTo(null);
          });
        }
        return;
      }
      // Older rows joined the buffer (a history merge), or it is new to the
      // window: everything from its oldest time comes from the buffer.
      final from = w.positionAt(oldest.timestamp);
      _liveStart = from;
      _replaceFrom(from, rows, rows.length - 1);
      return;
    }
    _liveStart = k;
    var p = k;
    var j = rows.length - 1;
    while (p < w.end && j >= 0 && identical(w[p], rows[j])) {
      p++;
      j--;
    }
    if (p == w.end) {
      if (j < 0) return;
      final from = w.end;
      w.append([for (var i = j; i >= 0; i--) rows[i]]);
      w.atNewest = true;
      if (_anchor <= from) _appendItems(from);
      return;
    }
    _replaceFrom(p, rows, j);
  }

  /// Replaces window rows from [from] on with [rows] from index [j] down to
  /// the newest, holding the row on screen unless following.
  void _replaceFrom(int from, List<TwitchMessage> rows, int j) {
    final w = _window;
    if (!_follow) _captureHold();
    w.trimFrom(from);
    w.append([for (var i = j; i >= 0; i--) rows[i]]);
    w.atNewest = true;
    _anchor = _anchor.clamp(w.first, w.end);
    _rebuildItems();
    // Equal-height changes leave the extents alone; this makes the viewport
    // run the physics anyway, so the hold applies.
    if (_hold != null) _pos?.correctBy(0);
  }

  /// Records the row at the viewport's bottom edge, for [_resolve].
  void _captureHold() {
    final at = _rowAtEdge();
    if (at == null) return;
    _hold = (
      key: HistoryWindow.keyOf(at.row),
      coord: at.bottom,
      height: at.top - at.bottom,
    );
  }

  /// The row crossing the viewport's bottom edge, with the scroll
  /// coordinates of its edges, from the last layout.
  ({TwitchMessage row, double bottom, double top})? _rowAtEdge() {
    final pos = _pos;
    if (pos == null || !pos.hasPixels) return null;
    final edge = pos.pixels;
    for (final older in const [true, false]) {
      final sliver = _sliver(older ? _olderKey : _newerKey);
      final items = older ? _olderItems : _newerItems;
      for (
        RenderBox? c = sliver?.firstChild;
        c != null;
        c = sliver!.childAfter(c)
      ) {
        final pd = c.parentData! as SliverMultiBoxAdaptorParentData;
        final i = pd.index;
        final offset = pd.layoutOffset;
        if (i == null || offset == null || i >= items.length) continue;
        final item = items[i];
        if (item.marker != null) continue;
        final bottom = older ? offset : -(offset + c.size.height);
        final top = older ? offset + c.size.height : -offset;
        if (bottom <= edge && top > edge) {
          final row = _window.at(item.pos);
          return row == null ? null : (row: row, bottom: bottom, top: top);
        }
      }
    }
    return null;
  }

  /// Scroll coordinate of the bottom edge of the row keyed [key] and
  /// [height], from the current layout. Reads layout offsets only, so it is
  /// safe during the viewport's layout.
  double? _coordOf(String key, double height) {
    for (final older in const [true, false]) {
      final sliver = _sliver(older ? _olderKey : _newerKey);
      final items = older ? _olderItems : _newerItems;
      for (
        RenderBox? c = sliver?.firstChild;
        c != null;
        c = sliver!.childAfter(c)
      ) {
        final pd = c.parentData! as SliverMultiBoxAdaptorParentData;
        final i = pd.index;
        final offset = pd.layoutOffset;
        if (i == null || offset == null || i >= items.length) continue;
        final item = items[i];
        if (item.marker != null) continue;
        final row = _window.at(item.pos);
        if (row != null && HistoryWindow.keyOf(row) == key) {
          return older ? offset : -(offset + height);
        }
      }
    }
    return null;
  }

  /// Physics hook, run in the layout that applies new content.
  double? _resolve(ScrollMetrics m) {
    if (_follow && _window.atNewest) return m.minScrollExtent;
    final hold = _hold;
    if (hold == null) return null;
    _hold = null;
    final now = _coordOf(hold.key, hold.height);
    if (now == null) return null;
    return (m.pixels + now - hold.coord).clamp(
      m.minScrollExtent,
      m.maxScrollExtent,
    );
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    _scheduleGateSync();
    final m = n.metrics;
    final atEnd =
        _window.atNewest && m.pixels <= m.minScrollExtent + _followEps;
    // A finger held at the newest row keeps following, so arrivals during
    // the drag cannot leave it above the bottom on release.
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _follow = atEnd;
    } else if (n is ScrollEndNotification && atEnd) {
      _follow = true;
    }
    _syncAtBottom(m);
    return false;
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
    if (_window.isEmpty) {
      if (!_window.atOldest) _loadOlder();
      return;
    }
    if (_scrolled) {
      _scrolled = false;
      _updateRail();
    }
    final ahead = pos.viewportDimension * 4;
    if (pos.maxScrollExtent - pos.pixels < ahead && !_window.atOldest) {
      _loadOlder();
    }
    if (pos.pixels - pos.minScrollExtent < ahead && !_window.atNewest) {
      _loadNewer();
    }
    _maybeReanchor(pos);
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    _loadingOlder = true;
    final epoch = _epoch;
    final edge = _window.isEmpty ? null : _window[_window.first].timestamp;
    var rows = await (edge == null
        ? widget.source.newest()
        : widget.source.older(edge));
    if (!mounted || epoch != _epoch) return;
    _loadingOlder = false;
    // The read can return only rows already held when several share the
    // edge's timestamp; step past them once before calling it the oldest.
    if (edge != null && rows.isNotEmpty && !_hasFresh(rows)) {
      _loadingOlder = true;
      rows = await widget.source.older(
        edge.subtract(const Duration(milliseconds: 1)),
      );
      if (!mounted || epoch != _epoch) return;
      _loadingOlder = false;
    }
    final first = _window.isEmpty ? null : _window[_window.first].timestamp;
    if (edge != null && first != edge) return;
    // Live rows may have landed while reading; older rows stay older.
    final fresh = first == null
        ? rows
        : [
            for (final r in rows)
              if (!r.timestamp.isAfter(first)) r,
          ];
    setState(() {
      if (_window.prepend(fresh) == 0) _window.markOldest();
      _trim();
      _rebuildItems();
    });
    _count('hblk');
    _scheduleMaintain();
  }

  Future<void> _loadNewer() async {
    if (_loadingNewer) return;
    _loadingNewer = true;
    final epoch = _epoch;
    final edge = _window[_window.end - 1].timestamp;
    var rows = await widget.source.newer(edge);
    if (!mounted || epoch != _epoch) return;
    _loadingNewer = false;
    if (rows.isNotEmpty && !_hasFresh(rows)) {
      _loadingNewer = true;
      rows = await widget.source.newer(
        edge.add(const Duration(milliseconds: 1)),
      );
      if (!mounted || epoch != _epoch) return;
      _loadingNewer = false;
    }
    if (_window[_window.end - 1].timestamp != edge) return;
    setState(() {
      if (_window.append(rows) == 0) _attachLive();
      _trim();
      _rebuildItems();
    });
    _count('hblk');
    _scheduleMaintain();
  }

  bool _hasFresh(List<TwitchMessage> rows) {
    final w = _window;
    final held = {
      for (var p = w.first; p < w.end; p++) HistoryWindow.keyOf(w[p]),
    };
    return rows.any((r) => !held.contains(HistoryWindow.keyOf(r)));
  }

  /// Drops far-end rows while the window exceeds the cap. Only rows fully
  /// beyond the anchor go, and only when the viewport is clear of them.
  void _trim() {
    final v = _viewportPos();
    final w = _window;
    while (w.length > _cap) {
      final dropOlder = v - w.first >= w.end - v;
      if (dropOlder) {
        final to = w.first + _trimChunk;
        // The live rows stay whole, so a buffer above the cap keeps its
        // mirror; [_syncLive] matches from [_liveStart].
        if (v - to < _keepNear ||
            to > _anchor ||
            (_liveAttached && to > _liveStart)) {
          return;
        }
        w.trimBefore(to);
      } else {
        final from = w.end - _trimChunk;
        if (from - v < _keepNear || from < _anchor) return;
        w.trimFrom(from);
        _liveAttached = false;
      }
      _count('hdrop');
    }
  }

  /// Position at the viewport's bottom edge, or [up] pixels above it, from
  /// the last layout; the anchor when nothing is built.
  int _viewportPos([double up = 0]) {
    final pos = _pos;
    if (pos == null || !pos.hasPixels) return _anchor;
    final p = pos.pixels + up;
    final older = p > 0;
    final sliver = _sliver(older ? _olderKey : _newerKey);
    final edge = older ? p : -p;
    final items = older ? _olderItems : _newerItems;
    // At the list's very end the edge sits exactly on the last built row's
    // far side, so no row crosses it; that last row is the viewport row.
    int? last;
    for (
      RenderBox? c = sliver?.firstChild;
      c != null;
      c = sliver!.childAfter(c)
    ) {
      final pd = c.parentData! as SliverMultiBoxAdaptorParentData;
      final offset = pd.layoutOffset;
      final index = pd.index;
      if (offset == null || index == null || index >= items.length) continue;
      if (offset + c.size.height > edge) return items[index].pos;
      last = items[index].pos;
    }
    return last ?? _anchor;
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
    if (firstIndex == null || firstIndex < _reanchorItems) return;
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
    // The older sliver must keep enough items to span the viewport.
    if (older && items.length - index < _minOlderItems) return;
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
    // The built rows from the target on keep their sliver and shift down by
    // the target's index and offset; handing both over lets the sliver move
    // them instead of rebuilding every visible row.
    final moves = older ? _olderMoves : _newerMoves;
    for (RenderBox? c = child; c != null; c = sliver!.childAfter(c)) {
      final d = c.parentData! as SliverMultiBoxAdaptorParentData;
      final i = d.index;
      final o = d.layoutOffset;
      if (i == null || o == null || i >= items.length) continue;
      moves.indexOf[_itemKey(items[i])] = i - index;
      moves.offsets[i - index] = o - offset;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => moves.clear());
    setState(() {
      _anchor = older ? target.pos + 1 : target.pos;
      _trim();
      _rebuildItems();
    });
    _count('hanc');
    _log(
      're-anchor to $_anchor shift=${offset.round()}px win=${_window.length}',
    );
    _scheduleMaintain();
  }

  // ---- Rail ----------------------------------------------------------------

  /// Builds the activity-weighted rail model on the first scroll, so opening
  /// a page never waits on it. A fresh archive has no sealed minutes yet, so
  /// a missing or bucket-old rail rebuilds on later scrolls.
  Future<void> _buildRail() async {
    if (!mounted || _railBuilding) return;
    final rail = _railReady.value;
    if (rail != null &&
        widget.source.now().difference(rail.to) < ActivityRail.defaultBucket) {
      return;
    }
    _railBuilding = true;
    try {
      final next = await widget.source.rail(_window.streams);
      if (mounted && next != null) _railReady.value = next;
    } finally {
      _railBuilding = false;
    }
  }

  /// Follows the list on scroll: shows the rail after a long scroll up and
  /// keeps the thumb on the viewport's time while visible.
  void _updateRail() {
    _peek.value = false;
    if (_firstPainted) _buildRail();
    final rail = _railReady.value;
    if (rail == null || _railDragging) return;
    final pos = _pos!;
    // The middle row, where a rail jump puts its target.
    final row = _window.at(_viewportPos(pos.viewportDimension / 2));
    if (row == null) return;
    if (!_railVisible.value) {
      final w = _window;
      // Off the newest end of the window the viewport is surely far back.
      if (w.atNewest) {
        final behind = w.end - _viewportPos();
        final age = w[w.end - 1].timestamp.difference(row.timestamp);
        if (behind < _railAfterRows && age < _railAfterAge) return;
      }
      _railVisible.value = true;
    }
    _thumb.value = rail.positionOf(row.timestamp);
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

  DateTime _timeAtRail(double pos) => _railReady.value!.timeAt(pos);

  void _onRailDragStart() {
    _railDragging = true;
    _peek.value = false;
    _bumpIdle();
  }

  /// Starts reading where the drag would land when no read is in flight, so
  /// the release usually finds its rows decoded.
  void _onRailDrag(double pos) {
    _bumpIdle();
    if (_prefetching) return;
    _prefetching = true;
    final t = _timeAtRail(pos);
    final rows = widget.source.around(t)
      ..whenComplete(() => _prefetching = false);
    _prefetched = (time: t, rows: rows);
  }

  Future<void> _onRailDragEnd(double pos) async {
    _railDragging = false;
    _bumpIdle();
    final pre = _prefetched;
    _prefetched = null;
    // The rail's ends mean the list's ends: the newest row, following, or
    // the oldest row at the top, not whatever sits mid-screen at that time.
    if (pos >= 1 - _railEndSnap) {
      _jumpToNewest();
      return;
    }
    final t = pos <= _railEndSnap
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : _timeAtRail(pos);
    Future<List<TwitchMessage>>? rows;
    if (pre != null) {
      final got = await pre.rows;
      if (!mounted) return;
      // Reuse the prefetch when the release lands inside what it read.
      if (got.isNotEmpty &&
          !t.isBefore(got.first.timestamp) &&
          !t.isAfter(got.last.timestamp)) {
        rows = Future.value(got);
      }
    }
    _jumpTo(t, fraction: 0.5, rows: rows);
  }

  /// Shows the rail with its bubble at [time], for a tapped day marker.
  void _peekRail(DateTime time) {
    _buildRail();
    final rail = _railReady.value;
    if (rail == null) return;
    _thumb.value = rail.positionOf(time);
    _peek.value = true;
    _railVisible.value = true;
    _bumpIdle();
  }

  // ---- Build ---------------------------------------------------------------

  /// The key [_item] gives the item's widget.
  String _itemKey(_Item item) =>
      item.marker?.key ?? HistoryWindow.keyOf(_window[item.pos]);

  Widget _item(BuildContext context, List<_Item> items, int j) {
    final item = items[j];
    final marker = item.marker;
    return marker == null
        ? _row(context, item.pos)
        : _markerRow(context, marker);
  }

  Widget _markerRow(BuildContext context, HistoryMarker m) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    if (_fmtLocale != locale) {
      _fmtLocale = locale;
      _dayFmt = DateFormat.MMMMEEEEd(locale);
      _shortDayFmt = DateFormat.MMMd(locale);
    }
    final stream = m.stream;
    final String text;
    Color? tint;
    switch (m.kind) {
      case HistoryMarkerKind.streamStart:
        text = l10n.historyStreamStarted(stream!.title, stream.game);
        tint = streamAccent;
      case HistoryMarkerKind.streamEnd:
        text = l10n.historyStreamEnded(
          formatStreamLength(stream!.end.difference(stream.start)),
        );
        tint = streamAccent;
      case HistoryMarkerKind.day:
        text = _dayFmt!.format(dayFromNumber(m.firstDay));
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
    }
    // A real system row, so it carries the timestamp, font and tint of live
    // system lines. A tap opens the marker sheet; empty stretches bring up the
    // rail at the marker's time.
    return KeyedSubtree(
      key: ValueKey<String>(m.key),
      child: _tile(
        context,
        TwitchMessage(
          login: '',
          text: text,
          isSystem: true,
          systemAccent: tint,
          messageId: m.key,
          channel: widget.channel,
          timestamp: m.time,
        ),
        m.kind == HistoryMarkerKind.emptyStretch
            ? () => _peekRail(m.time)
            : () => showHistoryMarkerSheet(
                context,
                title: text,
                stream: m.kind != HistoryMarkerKind.day,
              ),
      ),
    );
  }

  Widget _row(BuildContext context, int pos) {
    final msg = _window.at(pos);
    if (msg == null) return const SizedBox.shrink();
    final key = HistoryWindow.keyOf(msg);
    _scheduleGateSync();
    return RowGate(
      key: ValueKey<String>(key),
      gates: _gates,
      child: _cachedTile(context, msg, key, pos.isEven),
    );
  }

  /// The row's tile from the cache, touched on use so eviction drops rows
  /// scrolled away from, or a fresh one cached under its message id.
  Widget _cachedTile(
    BuildContext context,
    TwitchMessage msg,
    String key,
    bool alternate,
  ) {
    final cache = widget.tileCache?.putIfAbsent(widget.channel, () => {});
    final id = msg.messageId;
    final hit = id == null ? null : cache?.remove(id);
    if (hit != null) {
      cache![id] = hit;
      return hit;
    }
    final tile = widget.rows.tile(
      context,
      msg,
      alternate: alternate,
      scale: widget.textScale * _systemScale,
      surface: Theme.of(context).scaffoldBackgroundColor,
    );
    if (cache != null && id != null) {
      cache[id] = tile;
      if (cache.length > _maxCachedTiles) cache.remove(cache.keys.first);
    }
    return tile;
  }

  /// A derived marker row, styled like a live system line and tappable.
  Widget _tile(BuildContext context, TwitchMessage msg, VoidCallback onTap) {
    final r = widget.rows;
    final b = r.messageBuilder;
    return RepaintBoundary(
      child: ChatMessageTile(
        message: msg,
        channel: widget.channel,
        surface: Theme.of(context).scaffoldBackgroundColor,
        textScale: widget.textScale * _systemScale,
        showTimestamp: r.showTimestamp,
        timestampFormat: r.timestampFormat,
        lineSeparator: r.lineSeparator,
        buildBadgeSpans: b.buildBadgeSpans,
        buildMessageSpans: b.buildMessageSpans,
        bodyIsCached: b.bodyIsCached,
        onTap: onTap,
      ),
    );
  }

  /// The empty-state line, at the bottom like the first live row would be.
  Widget _empty(BuildContext context) => widget.rows.tile(
    context,
    TwitchMessage(
      login: '',
      text: widget.emptyText!,
      isSystem: true,
      channel: widget.channel,
    ),
    alternate: false,
    scale: widget.textScale * _systemScale,
    surface: Theme.of(context).scaffoldBackgroundColor,
  );

  @override
  Widget build(BuildContext context) {
    final scope = GlassChromeScope.maybeOf(context);
    final glass = (scope?.bottomClearance ?? 0) > 0.5;
    // Opaque in-flow composer sits flush under the list, so keep a small
    // fixed gap above it. Glass mode clears the measured pill instead, and
    // rows scroll on behind it.
    final pill = glass ? scope!.bottomClearance : 0.0;
    final bottom =
        (glass ? pill : kOpaqueComposerGap) + (scope?.listExtra ?? 0);
    _status =
        'win ${_window.length}  ${_window.first}-${_window.end}  '
        'anchor $_anchor';
    final empty = _window.isEmpty && widget.emptyText != null && _loaded;
    Widget list = NotificationListener<ScrollMetricsNotification>(
      // A viewport resize (keyboard) moves rows in or out of view without a
      // scroll.
      onNotification: (_) {
        _scheduleGateSync();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: CustomScrollView(
          controller: _controller,
          physics: defaultTargetPlatform == TargetPlatform.iOS
              ? _HoldBouncingPhysics(
                  parent: const AlwaysScrollableScrollPhysics(),
                  resolve: _resolve,
                )
              : _HoldClampingPhysics(resolve: _resolve),
          reverse: true,
          center: _olderKey,
          keyboardDismissBehavior: widget.keyboardDismissBehavior,
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: bottom)),
            if (empty) SliverToBoxAdapter(child: _empty(context)),
            _MovingSliverList(
              key: _newerKey,
              moves: _newerMoves,
              delegate: SliverChildBuilderDelegate(
                (ctx, j) => _item(ctx, _newerItems, j),
                childCount: _newerItems.length,
                findChildIndexCallback: _newerMoves.find,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
              ),
            ),
            _MovingSliverList(
              key: _olderKey,
              moves: _olderMoves,
              delegate: SliverChildBuilderDelegate(
                (ctx, j) => _item(ctx, _olderItems, j),
                childCount: _olderItems.length,
                findChildIndexCallback: _olderMoves.find,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: widget.topPadding)),
          ],
        ),
      ),
    );
    // iOS: a tap on empty chat space dismisses the keyboard. Rows are
    // InkWells, so their own taps win the arena and never dismiss.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      list = GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: list,
      );
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        list,
        // Clear of the menu trigger and the minimized cards bar beside it at
        // the top, and of the scroll-down button, which shows whenever the
        // rail does, at the bottom.
        Positioned(
          top:
              widget.topPadding +
              (widget.debugControls
                  ? 56
                  : kChromeMenuMargin + ChatWidgetMinimizedBar.height + 8),
          right: 0,
          bottom: max(bottom, 16 + pill + _fabSize) + 8,
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
        if (widget.atBottomNotifier case final atBottom?)
          ValueListenableBuilder<bool>(
            valueListenable: atBottom,
            builder: (_, value, _) => Positioned(
              right: 16,
              bottom: 16 + pill,
              child: ScrollDownButton(
                atBottom: value,
                glass: glass,
                heroTag:
                    widget.scrollFabHeroTag ?? 'scroll_down_${widget.channel}',
                onPressed: _jumpToNewest,
              ),
            ),
          ),
        if (widget.debugControls)
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
            button('newest', () => _jumpTo(null)),
            for (final d in const [1, 3, 7, 14, 29])
              button('${d}d', () => _jumpDaysAgo(d)),
          ],
        ),
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          child: Text(
            '${widget.channel}  $_status',
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ],
    );
  }
}
