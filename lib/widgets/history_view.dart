import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
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
import 'chrome_menu_button.dart';
import 'glass_chrome.dart';
import 'history_days.dart';
import 'history_streams.dart';

/// What a history page can do with its days and streams beyond reading them.
class HistoryActions {
  const HistoryActions({
    required this.keptDays,
    required this.keepDay,
    required this.findVod,
    required this.thumbnails,
    required this.watchVod,
    required this.follow,
    required this.vodLive,
  });

  /// Starts of the days kept past retention.
  final Future<Set<DateTime>> Function() keptDays;

  /// Keeps or releases the day from the first instant to the second.
  final Future<void> Function(DateTime start, DateTime end, bool keep) keepDay;

  /// The video on demand of a stream, null when it has none.
  final Future<String?> Function(HistoryStream stream) findVod;

  /// Thumbnail URLs by stream id, for the streams that still have a video.
  final Future<Map<String, String>> Function() thumbnails;

  /// Plays the video on demand of a stream.
  final void Function(HistoryStream stream, String vodId) watchVod;

  /// The playing VOD's channel and archive time; the matching page follows.
  final ValueListenable<({String channel, DateTime time})?> follow;

  /// The viewer chose live chat while the VOD plays.
  final ValueNotifier<bool> vodLive;
}

/// Windowed history list over a [HistorySource].
///
/// One reversed `CustomScrollView` with a `center` sliver. The center sliver
/// holds items older than [_anchor], the sliver before it holds newer items.
/// An item is a row or a derived marker (stream start/end, day, empty
/// stretch) that sits before its row in time. Rows load at the edge being
/// approached and drop from the far edge ([HistoryWindow]). When the viewport
/// drifts [_reanchorItems] items from the anchor, the anchor moves to the
/// viewport and `correctBy` keeps the content still, so the far ends can trim
/// without moving anything on screen. The menu's calendar opens the days
/// ([HistoryDays]), which jump through [_jumpTo].
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
    this.channelPage = false,
    required this.source,
    required this.rows,
    this.textScale = 1.0,
    this.topPadding = 0,
    this.debugControls = false,
    this.live,
    this.liveFirst = true,
    this.newestRows,
    this.liveVersion,
    this.emotesVersion,
    this.tileCache,
    this.atBottomNotifier,
    this.onScrollActivity,
    this.scrollFabHeroTag,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.emptyText,
    this.emptyStretches = true,
    this.jumpRequest,
    this.calendarRequest,
    this.actions,
    this.underCornerMenu = false,
  });

  final String channel;

  /// Whether this list is [channel]'s page, which clears [channel]'s island
  /// rather than the one on screen.
  final bool channelPage;
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

  /// Whether opening at the newest rows starts from [live] and reads the
  /// source behind it, so live chat never waits on the source. Off when the
  /// caller already waited for the source's newest rows (search).
  final bool liveFirst;

  /// The source's newest rows, already read. Opening at the newest rows
  /// uses them without a read, so the first frame already shows them.
  final List<TwitchMessage>? newestRows;

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

  /// Marks whole days with nothing recorded; off for search results.
  final bool emptyStretches;

  /// A time to show, centered (a tapped search result). Consumed and reset
  /// to null on open or whenever it is set.
  final ValueNotifier<DateTime?>? jumpRequest;

  /// Set true (the menu's calendar) to open the days; consumed and reset to
  /// false.
  final ValueNotifier<bool>? calendarRequest;

  /// Keeping days and watching VODs; null offers neither.
  final HistoryActions? actions;

  /// Whether the view menu floats in the top-right corner (fullscreen), so
  /// the VOD chat toggle sits under it.
  final bool underCornerMenu;

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
/// Starts a new scroll position where [start] says, read when the list first
/// lays out, so a list opening at its newest row needs no jump a frame later.
class _StartController extends ScrollController {
  _StartController(this.start);

  final double Function() start;

  @override
  double get initialScrollOffset => start();
}

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
  static const int _cap = 1200;

  /// Rows trimmed at once from a far end.
  static const int _trimChunk = 256;

  /// Items between viewport and anchor that trigger a re-anchor.
  static const int _reanchorItems = 400;

  /// Rows landing at once, while following, that move the anchor to them.
  static const int _catchUpItems = 60;

  /// Items the older sliver keeps so it always spans more than a viewport. The
  /// viewport floors its scroll max at the anchor, so a shorter older sliver
  /// would let the list scroll past the oldest row into empty space.
  static const int _minOlderItems = 80;

  /// Rows kept on each side of the viewport when trimming.
  static const int _keepNear = 300;

  static final Map<String, int> _counters = {};
  static _HistoryViewState? _active;

  late final ScrollController _controller = _StartController(
    () => _follow ? -_bottomGap : 0,
  );

  /// The newer end's padding: the newest row rests this far above offset 0.
  double get _bottomGap {
    final island = _island;
    if (island == null) return kOpaqueComposerGap;
    return island.listGap(page: widget.channelPage ? widget.channel : null);
  }

  IslandMetrics? _island;
  final GlobalKey _olderKey = GlobalKey();
  final GlobalKey _newerKey = GlobalKey();
  final _Moves _olderMoves = _Moves();
  final _Moves _newerMoves = _Moves();
  late final HistoryWindow _window = HistoryWindow(
    now: widget.source.now,
    emptyStretches: widget.emptyStretches,
  );
  final Stopwatch _open = Stopwatch()..start();
  List<_Item> _newerItems = const [];
  List<_Item> _olderItems = const [];
  bool _loadingOlder = false;
  bool _loadingNewer = false;

  /// The days rail, built when the days first open.
  final ValueNotifier<ActivityRail?> _railReady = ValueNotifier(null);

  /// The days are open: the list dims under them.
  final ValueNotifier<bool> _panel = ValueNotifier(false);
  bool _railBuilding = false;

  /// Day numbers kept past retention, as of the last read.
  final ValueNotifier<Set<int>> _kept = ValueNotifier(const {});

  /// The VOD time the list shows chat up to, while it replays a VOD.
  DateTime? _replayAt;

  /// The last VOD time seen, to tell a seek from playback.
  DateTime? _playedTo;

  /// Rows after the window's end, read ahead of the VOD. Oldest first.
  List<TwitchMessage> _replayQueue = [];

  /// Reading rows after [_replayQueue] from the source.
  _ReadAhead _readAhead = _ReadAhead.idle;

  /// A replay load is in flight; ticks wait for it. Counts loads, so only
  /// the latest one clears it.
  int _replayLoads = 0;
  bool _replayJumping = false;

  /// Why the replay waits, if it does.
  _ReplayPause _replayPause = _ReplayPause.none;

  bool _scrolled = false;
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

  /// Sticks to the newest row as rows arrive. Only a user drag or wheel
  /// clears it; coming to rest on the newest row sets it again.
  bool _follow = true;

  // True while a wheel or trackpad scroll event is being applied. Its scroll
  // carries no drag details, so this marks it as the reader's own.
  bool _pointerScroll = false;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _pointerScroll = true;
    // The list applies the scroll before this event's task ends.
    scheduleMicrotask(() => _pointerScroll = false);
  }

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
  bool _blankReported = false;

  /// Cache extent while a jump to the oldest end lays out: the rows above
  /// the anchor all build, so the end lands exact instead of on an estimate
  /// it then corrects in view.
  ScrollCacheExtent? _endCache;
  static const _endCacheExtent = ScrollCacheExtent.pixels(4000);
  String _status = '';

  /// Frame timings of the first moments after opening, for one log line.
  void Function(List<FrameTiming>)? _openTimings;
  Timer? _openProbe;

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
    widget.jumpRequest?.addListener(_onJumpRequest);
    widget.calendarRequest?.addListener(_onCalendarRequest);
    widget.actions?.follow.addListener(_onFollow);
    _unwatchClears = widget.source.watchClears(_onClear);
    _unwatchStreams = widget.source.watchStreams(_loadStreams);
    if (debugLogEnabled) _probeOpen();
  }

  /// Logs the frames of the first moments after opening: how many ran long,
  /// the worst build and raster, and how many images were already decoded,
  /// which is none after a return from the background.
  void _probeOpen() {
    final images = PaintingBinding.instance.imageCache.currentSize;
    var frames = 0, slow = 0, build = 0, raster = 0;
    void onTimings(List<FrameTiming> timings) {
      for (final t in timings) {
        frames++;
        if (t.totalSpan.inMilliseconds > 16) slow++;
        build = max(build, t.buildDuration.inMilliseconds);
        raster = max(raster, t.rasterDuration.inMilliseconds);
      }
    }

    _openTimings = onTimings;
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    _openProbe = Timer(const Duration(milliseconds: 1500), () {
      _endOpenProbe();
      _log(
        'open ${widget.channel}: frames=$frames slow=$slow '
        'worst build=${build}ms raster=${raster}ms images=$images',
      );
    });
  }

  void _endOpenProbe() {
    _openProbe?.cancel();
    _openProbe = null;
    final cb = _openTimings;
    _openTimings = null;
    if (cb != null) SchedulerBinding.instance.removeTimingsCallback(cb);
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
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    if (!_started) {
      // Tiles cached at this scale stay valid; a mounted page clears them
      // when the scale changes.
      _systemScale = scale;
      _started = true;
      _start();
    } else if (scale != _systemScale) {
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
    if (old.jumpRequest != widget.jumpRequest) {
      old.jumpRequest?.removeListener(_onJumpRequest);
      widget.jumpRequest?.addListener(_onJumpRequest);
    }
    if (old.calendarRequest != widget.calendarRequest) {
      old.calendarRequest?.removeListener(_onCalendarRequest);
      widget.calendarRequest?.addListener(_onCalendarRequest);
    }
    if (old.actions?.follow != widget.actions?.follow) {
      old.actions?.follow.removeListener(_onFollow);
      widget.actions?.follow.addListener(_onFollow);
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
    final request = widget.jumpRequest?.value;
    if (request != null) {
      widget.jumpRequest!.value = null;
      _jumpTo(request, fraction: 0.5);
    } else if (saved == null) {
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

  void _onJumpRequest() {
    final time = widget.jumpRequest?.value;
    if (time == null) return;
    widget.jumpRequest!.value = null;
    _jumpTo(time, fraction: 0.5);
  }

  Future<void> _onCalendarRequest() async {
    final r = widget.calendarRequest;
    if (r == null || !r.value) return;
    r.value = false;
    await _openDays();
  }

  /// Re-reads the kept days.
  Future<void> _refreshKept() async {
    final actions = widget.actions;
    if (actions == null) return;
    final starts = await actions.keptDays();
    if (mounted) {
      _kept.value = {for (final s in starts) dayNumber(s.toLocal())};
    }
  }

  Future<void> _keepDay(int day, bool keep) async {
    final bounds = dayBounds(day);
    await widget.actions!.keepDay(bounds.start, bounds.end, keep);
    await _refreshKept();
  }

  /// The sheet for a day, with a stream's VOD when it is a stream's row.
  Future<void> _showSheet(
    String title,
    int day, {
    HistoryStream? stream,
    bool jumpToStart = false,
  }) async {
    final actions = widget.actions;
    await _refreshKept();
    if (!mounted) return;
    await showHistoryMarkerSheet(
      context,
      title: title,
      stream: stream != null,
      vod: stream == null ? null : actions?.findVod(stream),
      onWatchVod: actions == null || stream == null
          ? null
          : (id) => actions.watchVod(stream, id),
      onJumpToStart: stream == null || !jumpToStart
          ? null
          : () => _jumpTo(stream.start, fraction: _startFraction),
      onOpenStreamMap: stream == null
          ? null
          : () {
              _calendarTime = stream.start;
              unawaited(_openDays());
            },
      onOpenInStreams: stream == null ? null : () => _openStreams(stream),
      kept: actions == null ? null : _kept.value.contains(day),
      onKeep: actions == null ? null : (keep) => _keepDay(day, keep),
    );
  }

  void _onDayLongPress(int day) {
    final locale = Localizations.localeOf(context).toString();
    unawaited(
      _showSheet(DateFormat.MMMMEEEEd(locale).format(dayFromNumber(day)), day),
    );
  }

  /// Replays chat with a playing VOD: the list shows chat up to the VOD's
  /// time and takes in rows as playback reaches them, like live chat. A
  /// seek reloads around the new time, as does [reload] (resuming a replay
  /// a jump elsewhere held). Closing the VOD returns to the newest row.
  void _onFollow({bool reload = false}) {
    final at = widget.actions?.follow.value;
    if (at == null) {
      _playedTo = null;
      if (_replayAt != null) _endReplay();
      return;
    }
    if (at.channel != widget.channel) {
      // The VOD moved to another channel.
      if (_replayAt != null) _endReplay();
      return;
    }
    final played = _playedTo;
    _playedTo = at.time;
    if (widget.actions!.vodLive.value) return;
    final seek = played != null && at.time.difference(played).abs() > _seekGap;
    final held = reload || _replayPause == _ReplayPause.held;
    if (seek) _replayPause = _ReplayPause.none;
    if (_replayPause != _ReplayPause.none) return;
    final shown = _replayAt;
    // Far behind (back from a pause) reloads rather than reading every
    // block in between.
    if (shown == null ||
        seek ||
        held ||
        at.time.isBefore(shown) ||
        at.time.difference(shown) > _replayAhead) {
      _startReplay(at.time);
    } else {
      _advanceReplay(at.time);
    }
  }

  /// A VOD time step larger than this is a seek, not playback. Ticks come
  /// about once a second, twice that at double speed.
  static const _seekGap = Duration(seconds: 4);

  /// Rows the replay reads ahead of the VOD, at least.
  static const _replayAhead = Duration(minutes: 2);

  /// Loads the chat up to [time] and pins the list to its newest row.
  void _startReplay(DateTime time) {
    _replayAt = time;
    _replayQueue = [];
    _readAhead = _ReadAhead.idle;
    _replayPause = _ReplayPause.none;
    _replayJumping = true;
    final load = ++_replayLoads;
    final source = widget.source;
    final rows = source.around(time).then((rows) {
      if (load == _replayLoads) {
        _replayQueue = [
          for (final m in rows)
            if (m.timestamp.isAfter(time)) m,
        ];
      }
      return [
        for (final m in rows)
          if (!m.timestamp.isAfter(time)) m,
      ];
    });
    _jumpTo(time, rows: rows, replay: true).whenComplete(() {
      if (load == _replayLoads) _replayJumping = false;
    });
  }

  /// Whether [m] is deleted only later than the replay has reached, so it
  /// still shows unfaded.
  bool _deletedLater(TwitchMessage m) {
    final at = _replayAt;
    final deletedAt = m.deletedAt;
    return at != null &&
        m.deleted &&
        deletedAt != null &&
        deletedAt.isAfter(at);
  }

  /// Moves the replay on to [time]: queued rows it has reached join the
  /// list, and the queue reads ahead when it runs short.
  void _advanceReplay(DateTime time) {
    final before = _replayAt;
    _replayAt = time;
    // Rows whose delete the replay just passed fade now.
    if (before != null) {
      final w = _window;
      for (var p = w.first; p < w.end; p++) {
        final d = w[p].deletedAt;
        if (d != null && d.isAfter(before) && !d.isAfter(time)) {
          setState(() {});
          break;
        }
      }
    }
    if (!_loaded || _loadingNewer || _replayJumping) return;
    final due = <TwitchMessage>[];
    var k = 0;
    while (k < _replayQueue.length &&
        !_replayQueue[k].timestamp.isAfter(time)) {
      due.add(_replayQueue[k++]);
    }
    if (k > 0) _replayQueue = _replayQueue.sublist(k);
    if (due.isNotEmpty) {
      setState(() {
        final w = _window;
        final from = w.end;
        w.append(due);
        if (w.length > _cap) {
          _trim();
          _rebuildItems();
        } else {
          _appendItems(from);
        }
      });
      _scheduleMaintain();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = _pos;
        if (!mounted || p == null || !p.hasContentDimensions) return;
        _snapToNewest(p);
        _syncAtBottom(p);
      });
    }
    final ahead = _replayQueue.isEmpty
        ? null
        : _replayQueue.last.timestamp.difference(time);
    if (_readAhead != _ReadAhead.done &&
        (ahead == null || ahead < _replayAhead)) {
      unawaited(_readReplay());
    }
  }

  /// Reads the next block after the queue (or the window) into the queue.
  Future<void> _readReplay() async {
    if (_readAhead == _ReadAhead.reading) return;
    final epoch = _epoch;
    final tail = _replayQueue.isNotEmpty
        ? _replayQueue.last
        : (_window.isEmpty ? null : _window[_window.end - 1]);
    final edge = tail?.timestamp ?? _replayAt;
    if (edge == null) return;
    _readAhead = _ReadAhead.reading;
    try {
      final held = {
        for (final m in _replayQueue) HistoryWindow.keyOf(m),
        for (var p = _window.first; p < _window.end; p++)
          HistoryWindow.keyOf(_window[p]),
      };
      var rows = await widget.source.newer(edge);
      var fresh = [
        for (final m in rows)
          if (!held.contains(HistoryWindow.keyOf(m))) m,
      ];
      if (fresh.isEmpty && rows.isNotEmpty) {
        // A block of rows sharing the edge's time: step past it.
        rows = await widget.source.newer(
          edge.add(const Duration(milliseconds: 1)),
        );
        fresh = [
          for (final m in rows)
            if (!held.contains(HistoryWindow.keyOf(m))) m,
        ];
      }
      if (!mounted || epoch != _epoch) return;
      if (fresh.isEmpty) {
        _readAhead = _ReadAhead.done;
        return;
      }
      _replayQueue = [..._replayQueue, ...fresh];
    } catch (e) {
      logDebug('[hist!] ${widget.channel}: replay read failed: $e');
    } finally {
      if (epoch == _epoch && _readAhead == _ReadAhead.reading) {
        _readAhead = _ReadAhead.idle;
      }
    }
    final at = _replayAt;
    if (mounted && epoch == _epoch && at != null) _advanceReplay(at);
  }

  /// Flips between live chat and the replay of the playing VOD.
  void _toggleVodChat() {
    final actions = widget.actions!;
    final at = actions.follow.value;
    if (at == null) return;
    final live = actions.vodLive.value = !actions.vodLive.value;
    if (live) {
      _endReplay();
    } else {
      _startReplay(at.time);
    }
  }

  /// Leaves the replay for the newest rows.
  void _endReplay() {
    _replayAt = null;
    _replayPause = _ReplayPause.none;
    _replayJumping = false;
    _replayLoads++;
    _replayQueue = [];
    _readAhead = _ReadAhead.idle;
    _jumpTo(null);
  }

  /// A time the next calendar open goes straight to (a stream's start).
  DateTime? _calendarTime;

  /// A stream's first row lands mid-screen, with the chat before it above.
  static const _startFraction = 0.5;

  Future<void> _openDays() async {
    await _buildRail();
    unawaited(_refreshKept());
    final rail = _railReady.value;
    if (!mounted || rail == null || !HistoryDays.hasDays(rail)) return;
    // The drawer covers the composer, so the keyboard goes with it.
    FocusManager.instance.primaryFocus?.unfocus();
    _panel.value = true;
  }

  /// An outside write of true (a tab tap) asks for the newest row.
  void _onAtBottomRequest() {
    final n = widget.atBottomNotifier;
    if (n != null && n.value && !_atBottom) _jumpToNewest();
  }

  /// Back to the newest row: a scroll when it is already near, otherwise a
  /// fresh window.
  void _jumpToNewest() {
    final replay = _replayAt;
    if (replay != null) {
      _startReplay(widget.actions?.follow.value?.time ?? replay);
      return;
    }
    _follow = true;
    _atBottom = true;
    _panel.value = false;
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

  /// Whether every row fits on screen at the newest end, so the list has one
  /// rest: its bottom padding alone would leave a few pixels to drag through.
  bool _fits(ScrollPosition p) {
    if (!_window.atOldest || !_window.atNewest) return false;
    final older = _sliver(_olderKey)?.geometry?.scrollExtent;
    return older != null &&
        older + widget.topPadding <=
            p.minScrollExtent + p.viewportDimension + _followEps;
  }

  /// Where the oldest row rests: the top, or the one rest of a list that fits.
  double _oldestEnd(ScrollPosition p) =>
      _fits(p) ? p.minScrollExtent : p.maxScrollExtent;

  /// Keeps a jump to either end on it for a few frames. Extents past the
  /// built rows are estimates until those rows lay out, so the first jump can
  /// fall short or overshoot. A new jump or a touch ends it.
  void _settleAtEnd({required bool oldest, int tries = 4}) {
    final epoch = _epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = _pos;
      var again = false;
      if (epoch == _epoch &&
          p != null &&
          p.hasContentDimensions &&
          !p.isScrollingNotifier.value &&
          (oldest || _follow)) {
        final end = oldest ? _oldestEnd(p) : p.minScrollExtent;
        if ((p.pixels - end).abs() > _followEps) {
          p.jumpTo(end);
          again = tries > 1;
        }
      }
      if (again) {
        _settleAtEnd(oldest: oldest, tries: tries - 1);
      } else if (oldest && _endCache != null) {
        setState(() => _endCache = null);
      }
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
    widget.jumpRequest?.removeListener(_onJumpRequest);
    widget.calendarRequest?.removeListener(_onCalendarRequest);
    widget.actions?.follow.removeListener(_onFollow);
    _unwatchClears?.call();
    _unwatchStreams?.call();
    if (identical(_active, this)) _active = null;
    if (PerfProbe.enabled) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    _endOpenProbe();
    _controller.dispose();
    _railReady.dispose();
    _panel.dispose();
    _kept.dispose();
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
    JankLog.note('hist $message');
    if (PerfProbe.enabled) AppLog.I.record('HIST', message);
  }

  /// Logs a state the list should never reach, under its own tag so one
  /// filter finds every report.
  void _warn(String message) {
    logDebug('[hist!] ${widget.channel}: $message');
    if (PerfProbe.enabled) AppLog.I.record('HIST!', message);
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
    bool replay = false,
  }) async {
    final epoch = ++_epoch;
    _loadingOlder = false;
    _loadingNewer = false;
    if (_replayAt != null && !replay && time != null) {
      // A jump elsewhere during a VOD (a picked day) holds the replay.
      _replayPause = _ReplayPause.held;
    }
    _follow = time == null || replay;
    _hold = null;
    final sw = Stopwatch()..start();
    final source = widget.source;
    // With a live buffer the newest rows are on hand; history prepends as it
    // reads, so the archive never holds up live chat.
    final liveFirst =
        widget.liveFirst && time == null && rows == null && widget.live != null;
    final ready = time == null && rows == null && !_loaded
        ? widget.newestRows
        : null;
    // Awaiting even a finished read paints a frame first, so rows on hand
    // skip the await.
    final loaded = liveFirst
        ? const <TwitchMessage>[]
        : ready ??
              await (rows ??
                  (time == null ? source.newest() : source.around(time)));
    if (!mounted || epoch != _epoch) return;
    // A target near the oldest row needs the rows above it before the anchor
    // can sit there; otherwise the older sliver could not span the viewport.
    var olderRows = const <TwitchMessage>[];
    var askedOlder = false;
    if (loaded.isNotEmpty && time != null) {
      final before = loaded.where((m) => m.timestamp.isBefore(time)).length;
      if (before < _minOlderItems) {
        // The read can return only rows already loaded when several share
        // the first one's timestamp; step past them before trusting it.
        final held = {for (final m in loaded) HistoryWindow.keyOf(m)};
        askedOlder = true;
        olderRows = await source.older(loaded.first.timestamp);
        if (!mounted || epoch != _epoch) return;
        if (olderRows.every((m) => held.contains(HistoryWindow.keyOf(m)))) {
          olderRows = await source.older(
            loaded.first.timestamp.subtract(const Duration(milliseconds: 1)),
          );
          if (!mounted || epoch != _epoch) return;
        }
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
        // Only a read that found nothing older makes this the oldest end.
        if (_window.prepend(olderRows) == 0 &&
            askedOlder &&
            olderRows.isEmpty) {
          _window.markOldest();
        }
      }
      _liveAttached = false;
      if (time == null) _attachLive();
      // A replay's rows end at the VOD's time, which is its newest row.
      if (replay) _window.atNewest = true;
      final target = time == null || replay
          ? _window.end
          : _window.positionAt(time);
      // At the oldest end the anchor moves newer so the older sliver stays
      // long enough; the list then rests on the oldest row.
      _anchor = _window.atOldest && target - _window.first < _minOlderItems
          ? (_window.first + _minOlderItems).clamp(_window.first, _window.end)
          : target;
      pinOldest = _anchor > target;
      if (pinOldest) _endCache = _endCacheExtent;
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
            ? _oldestEnd(p)
            : p.pixels.clamp(p.minScrollExtent, p.maxScrollExtent);
        if (clamped != p.pixels) p.jumpTo(clamped);
        _snapToNewest(p);
        _syncAtBottom(p);
        if (pinOldest) _settleAtEnd(oldest: true);
        if (time == null || replay) _settleAtEnd(oldest: false);
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
    if (!_liveAttached) return;
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
        m.deletedAt ??= clear.to;
        cache?.remove(m.messageId);
        hit = true;
      }
      if (hit) setState(() {});
    });
  }

  /// Clears the tokens of source rows parsed while catalogs were landing, so
  /// their next build parses against the fuller catalog.
  void _onEmotes() {
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
      if (_followAnchorFar(batch: w.end - from)) {
        _rebuildItems();
      } else if (_anchor <= from) {
        _appendItems(from);
      }
      return;
    }
    _replaceFrom(p, rows, j);
  }

  /// While following, moves the anchor to the newest row once more than a
  /// re-anchor's worth of rows sit past it, or a [batch] bigger than a
  /// screen lands at once (a page catching up after sitting inactive).
  /// Pinning to the newest row would otherwise lay out every row past the
  /// anchor in one frame. Returns whether it moved; the caller rebuilds the
  /// items.
  bool _followAnchorFar({int batch = 0}) {
    if (!_follow) return false;
    if (batch <= _catchUpItems && _window.end - _anchor <= _reanchorItems) {
      return false;
    }
    _anchor = _window.end;
    return true;
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
    _followAnchorFar(batch: j + 1);
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
    if (_follow && _window.atNewest) {
      // A drag past the newest row is the iOS bounce, so leave it alone.
      if (m.pixels < m.minScrollExtent) return null;
      return m.minScrollExtent;
    }
    final hold = _hold;
    if (hold == null) return null;
    _hold = null;
    final now = _coordOf(hold.key, hold.height);
    if (now == null) return null;
    final target = m.pixels + now - hold.coord;
    // The same at the oldest end: a bounce is not a content shift.
    if (target < m.minScrollExtent || target > m.maxScrollExtent) return null;
    return target;
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    _scheduleGateSync();
    final m = n.metrics;
    final atEnd =
        _window.atNewest && m.pixels <= m.minScrollExtent + _followEps;
    // A finger held at the newest row keeps following, so arrivals during
    // the drag cannot leave it above the bottom on release.
    if (n is ScrollUpdateNotification &&
        (n.dragDetails != null || _pointerScroll)) {
      _follow = atEnd;
      if (_replayAt != null && !atEnd && _replayPause == _ReplayPause.none) {
        _replayPause = _ReplayPause.scrolled;
      }
    } else if (n is ScrollEndNotification) {
      if (atEnd) {
        _follow = true;
        // Back at the bottom, the replay catches up with the VOD.
        if (_replayPause != _ReplayPause.none) {
          final reload = _replayPause == _ReplayPause.held;
          _replayPause = _ReplayPause.none;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _onFollow(reload: reload);
          });
        }
      } else if (_pos case final p? when _fits(p)) {
        _follow = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _follow) _snapToNewest(p);
        });
      }
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
      _checkBlank(pos);
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
    try {
      await _readOlder(epoch);
    } catch (e) {
      logDebug('[hist!] ${widget.channel}: older read failed: $e');
      if (epoch == _epoch) _loadingOlder = false;
    }
  }

  Future<void> _readOlder(int epoch) async {
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
    try {
      await _readNewer(epoch);
    } catch (e) {
      logDebug('[hist!] ${widget.channel}: newer read failed: $e');
      if (epoch == _epoch) _loadingNewer = false;
    }
  }

  Future<void> _readNewer(int epoch) async {
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
    // A replay shows nothing past the VOD's time.
    final replay = _replayAt;
    if (replay != null) {
      rows = [
        for (final m in rows)
          if (!m.timestamp.isAfter(replay)) m,
      ];
    }
    setState(() {
      if (_window.append(rows) == 0) {
        replay == null ? _attachLive() : _window.atNewest = true;
      }
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

  /// Reports once when neither sliver paints a row though the window holds
  /// some, with the extents that explain the blank.
  void _checkBlank(ScrollPosition pos) {
    final older = _sliver(_olderKey)?.geometry;
    final newer = _sliver(_newerKey)?.geometry;
    final blank =
        _window.length > 0 &&
        (older?.paintExtent ?? 0) == 0 &&
        (newer?.paintExtent ?? 0) == 0;
    if (blank && !_blankReported) {
      _warn(
        'blank viewport px=${pos.pixels.round()} '
        'ext=${pos.minScrollExtent.round()}..${pos.maxScrollExtent.round()} '
        'vp=${pos.viewportDimension.round()} '
        'older=${older?.scrollExtent.round()}/${_olderItems.length} '
        'newer=${newer?.scrollExtent.round()}/${_newerItems.length} '
        'win=${_window.first}..${_window.end} anchor=$_anchor '
        'oldest=${_window.atOldest} newest=${_window.atNewest} '
        'loading=$_loadingOlder/$_loadingNewer',
      );
    }
    _blankReported = blank;
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

  // ---- Days ----------------------------------------------------------------

  /// Builds the rail the days come from when they open. A fresh archive has
  /// no sealed minutes yet, so a missing or bucket-old rail rebuilds.
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

  /// The middle row's time, whose day the days highlight.
  DateTime? _viewTime() {
    final pos = _pos;
    if (pos == null || !pos.hasViewportDimension) return null;
    return _window.at(_viewportPos(pos.viewportDimension / 2))?.timestamp;
  }

  /// Every stream of the channel on its own page, scrolled to [focus]; a
  /// pick opens it at its start.
  void _openStreams([HistoryStream? focus]) {
    final streams = [..._window.streams]
      ..sort((a, b) => b.start.compareTo(a.start));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (page) => HistoryStreamsPage(
            streams: streams,
            thumbnails: widget.actions?.thumbnails(),
            focus: focus,
            onOpen: (stream) {
              Navigator.of(page).pop();
              _jumpTo(stream.start, fraction: _startFraction);
            },
          ),
        ),
      ),
    );
  }

  /// A time picked in the days, centered.
  void _onPick(DateTime time) => _jumpTo(time, fraction: 0.5);

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
            ? _openDays
            : () => _showSheet(
                text,
                m.kind == HistoryMarkerKind.day
                    ? m.firstDay
                    : dayNumber(m.time.toLocal()),
                stream: stream,
                jumpToStart: m.kind == HistoryMarkerKind.streamEnd,
              ),
      ),
    );
  }

  Widget _row(BuildContext context, int pos) {
    final msg = _window.at(pos);
    if (msg == null) return const SizedBox.shrink();
    final key = HistoryWindow.keyOf(msg);
    _scheduleGateSync();
    final stream = _streamOfRow(msg);
    return RowGate(
      key: ValueKey<String>(key),
      gates: _gates,
      child: stream == null
          ? _cachedTile(context, msg, key, pos.isEven)
          : _tile(
              context,
              msg,
              () => _showSheet(
                msg.text,
                dayNumber(msg.timestamp.toLocal()),
                stream: stream.stream,
                jumpToStart: stream.end,
              ),
            ),
    );
  }

  /// The stream behind the chat's own stream start or end row, which taps
  /// like the marker it stands in for.
  ({HistoryStream stream, bool end})? _streamOfRow(TwitchMessage msg) {
    final id = msg.messageId;
    const prefix = 'sys_stream:';
    if (!msg.isSystem || id == null || !id.startsWith(prefix)) return null;
    final streamId = id.substring(prefix.length, id.lastIndexOf(':'));
    for (final s in _window.streams) {
      if (s.id == streamId) return (stream: s, end: id.endsWith(':end'));
    }
    return null;
  }

  /// The checker stripe each cached tile was built with.
  static final _tileParity = Expando<bool>();

  /// The row's tile from the cache, touched on use so eviction drops rows
  /// scrolled away from, or a fresh one cached under its message id.
  Widget _cachedTile(
    BuildContext context,
    TwitchMessage msg,
    String key,
    bool alternate,
  ) {
    // Left out of the shared cache: live chat must never get the unfaded row.
    if (_deletedLater(msg)) {
      return widget.rows.tile(
        context,
        msg,
        alternate: alternate,
        scale: widget.textScale * _systemScale,
        surface: Theme.of(context).scaffoldBackgroundColor,
        fadeDeleted: false,
      );
    }
    final cache = widget.tileCache?.putIfAbsent(widget.channel, () => {});
    final id = msg.messageId;
    final hit = id == null ? null : cache?.remove(id);
    // A tile baked with the other stripe (after a jump or built by ChatView)
    // is rebuilt.
    if (hit != null && _tileParity[hit] == alternate) {
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
      _tileParity[tile] = alternate;
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
    final scope = IslandScope.maybeOf(context);
    final glass = scope?.glass ?? false;
    _island = scope?.metrics;
    final page = widget.channelPage ? widget.channel : null;
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
      child: Listener(
        onPointerSignal: _onPointerSignal,
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
            scrollCacheExtent: _endCache,
            center: _olderKey,
            keyboardDismissBehavior: widget.keyboardDismissBehavior,
            slivers: [
              // Sizes in layout, so the newest row clears the island in the
              // frame it moves.
              SliverToBoxAdapter(child: IslandSpacer(page: page, chat: true)),
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
        // The days open in the navigator's overlay, over the whole app.
        ValueListenableBuilder<ActivityRail?>(
          valueListenable: _railReady,
          builder: (context, rail, _) => rail == null
              ? const SizedBox.shrink()
              : HistoryDays(
                  rail: rail,
                  open: _panel,
                  viewTime: _viewTime,
                  onPick: _onPick,
                  kept: _kept,
                  onLongPress: _onDayLongPress,
                  takeOpenTime: () {
                    final time = _calendarTime;
                    _calendarTime = null;
                    return time;
                  },
                  onStreams: _openStreams,
                  glass: glass,
                ),
        ),
        if (widget.atBottomNotifier case final atBottom?)
          ValueListenableBuilder<bool>(
            valueListenable: atBottom,
            builder: (_, value, _) => Positioned.fill(
              child: IslandInset(
                page: page,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16, bottom: 16),
                    child: ScrollDownButton(
                      atBottom: value,
                      glass: glass,
                      heroTag:
                          widget.scrollFabHeroTag ??
                          'scroll_down_${widget.channel}',
                      onPressed: _jumpToNewest,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (widget.actions case final actions?)
          ListenableBuilder(
            listenable: Listenable.merge([actions.follow, actions.vodLive]),
            builder: (_, _) => actions.follow.value?.channel != widget.channel
                ? const SizedBox.shrink()
                : Positioned(
                    // Centered under the menu pill: the 44dp glass button
                    // sits 2dp in from the small FAB's 48dp tap target.
                    right: widget.underCornerMenu && glass ? 18 : 16,
                    top:
                        widget.topPadding +
                        kChromeMenuMargin +
                        // An 8dp gap under the menu pill; the small FAB's
                        // tap target already pads 4dp above it.
                        (widget.underCornerMenu
                            ? FloatingMenuShell.height + (glass ? 8 : 4)
                            : 0),
                    child: VodChatButton(
                      live: actions.vodLive.value,
                      glass: glass,
                      heroTag: 'vod_chat_${widget.channel}',
                      onPressed: _toggleVodChat,
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

/// Why a VOD replay waits. [scrolled]: the reader scrolled up, and coming
/// back to the bottom resumes. [held]: a jump elsewhere left the replay's
/// rows, so resuming reloads them.
enum _ReplayPause { none, scrolled, held }

/// The replay's read-ahead past its queue. [done]: the source has nothing
/// newer.
enum _ReadAhead { idle, reading, done }
