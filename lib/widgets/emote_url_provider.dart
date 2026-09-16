import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../emotes/emote.dart';
import '../util/log.dart';
import '../util/webp_anim.dart';
import '../services/emote_images.dart';
import 'emote_decode.dart';

/// Engine decode timeout for animated WebP streaming. Per-frame engine decode
/// costs milliseconds, so this only fires on a stalled engine, which then
/// falls back to the pure-Dart compositor instead of sitting for seconds.
const Duration _streamFrameTimeout = Duration(seconds: 1);

/// Whether [emote] renders through the custom completer loop. True for
/// animated non-Twitch emotes (animated WebP streams from the engine, and
/// frozen animated emotes render a first-frame still). Everything else
/// (statics of any provider, playing Twitch GIFs) resolves through the stock
/// provider: one shared engine decode per URL with no wrapper, no extra
/// completer, no registry entry. Shared routing rule for chat, menu, sheet,
/// and panel.
bool emoteUsesCustomLoop(Emote emote, {required bool animateGifs}) =>
    emote.isAnimated && (!animateGifs || emote.type != EmoteType.twitch);

/// ImageProvider for emote URLs. Keyed by [url] for shared decode/playback. Animated WebP streams from the engine; the pure-Dart compositor is a crash-only fallback.
class EmoteUrlProvider extends ImageProvider<EmoteUrlProvider> {
  EmoteUrlProvider(this.url, {required this.images});

  /// Test hook; falls back to the production fetcher when null.
  @visibleForTesting
  static Future<Uint8List> Function(String url)? debugFetchOverride;

  /// Test hook: when non-negative, the animated WebP engine stream fails after
  /// this many emitted frames, exercising the lazy compositor fallback.
  @visibleForTesting
  static int debugWebpEngineFailAfter = -1;

  final String url;
  final EmoteImages images;

  @override
  Future<EmoteUrlProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    EmoteUrlProvider key,
    ImageDecoderCallback decode,
  ) {
    return _EmoteImageCompleter(
      url: key.url,
      images: key.images,
      engineDecode: decode,
    );
  }

  /// Seeds queued by target URL for the next completer.
  static final Map<String, String> _pendingSeeds = {};

  /// Bound on queued seeds; a target that never renders drops the oldest.
  static const _maxPendingSeeds = 256;

  static void _storeSeed(String url, String sourceUrl) {
    _pendingSeeds[url] = sourceUrl;
    while (_pendingSeeds.length > _maxPendingSeeds) {
      _pendingSeeds.remove(_pendingSeeds.keys.first);
    }
  }

  /// Whether animated emotes play. False freezes at current frame. Synced
  /// from prefs.
  static bool gifsEnabled = true;

  /// Toggles emote animation, freezing/resuming live completers.
  static void applyGifsEnabled(bool enabled) {
    gifsEnabled = enabled;
    for (final completer in List.of(_liveByUrl.values)) {
      completer._refreshForAnimations();
    }
  }

  /// Live custom-loop completers by URL (animated WebP, playing GIFs,
  /// frozen stills). Engine-routable bytes never enter: they resolve through
  /// the stock provider at call sites, so this map no longer decides
  /// lifetime for the hot path. Entries leave on dispose (zero listeners).
  static final Map<String, _EmoteImageCompleter> _liveByUrl = {};

  /// Live completer count, for the growth probe.
  static int get liveCount => _liveByUrl.length;

  // ── Chat-surfaced frame capture ─────────────────────────────────────
  /// URLs rendered by the chat surface this session. Only these are eligible
  /// for decoded-frame capture, so menu/sheet/panel animation never consumes a
  /// capture slot.
  static final Map<String, int> _chatTouched = <String, int>{};
  static int _chatSeq = 0;
  static const _maxChatUrls = 512;

  /// Marks [url] as rendered in chat, enabling capture for its completer.
  static void markChatUse(String url) {
    _chatTouched.remove(url);
    _chatTouched[url] = ++_chatSeq;
    while (_chatTouched.length > _maxChatUrls) {
      _chatTouched.remove(_chatTouched.keys.first);
    }
  }

  static bool _isChatUrl(String url) => _chatTouched.containsKey(url);

  /// Captured animated emotes ordered by last touch, oldest first. Bounded so
  /// the decoded-frame cache cannot grow without limit.
  static final Map<String, int> _capturedOrder = <String, int>{};
  static int _capturedSeq = 0;
  static const maxCapturedEmotes = 20;

  /// Records that [url] holds captured frames and trims the oldest evictable
  /// entries. Visible emotes are never evicted; if every entry is active the
  /// cache is allowed to overflow until something scrolls away.
  static void _touchCaptured(String url) {
    _capturedOrder.remove(url);
    _capturedOrder[url] = ++_capturedSeq;
    while (_capturedOrder.length > maxCapturedEmotes) {
      String? victim;
      for (final candidate in _capturedOrder.keys) {
        final live = _liveByUrl[candidate];
        if (live == null || live._disposed || !live._visible) {
          victim = candidate;
          break;
        }
      }
      if (victim == null) break;
      final live = _liveByUrl[victim];
      _capturedOrder.remove(victim);
      if (live != null && !live._disposed) {
        PaintingBinding.instance.imageCache.evict(
          EmoteUrlProvider(victim, images: live.images),
        );
      }
    }
  }

  /// Whether [url]'s completer has captured a full cycle. Exposed for tests.
  @visibleForTesting
  static bool isFullyCaptured(String url) {
    final live = _liveByUrl[url];
    return live != null && !live._disposed && live._frames != null;
  }

  /// Captured frame count for [url], or 0. Exposed for tests.
  @visibleForTesting
  static int capturedFrameCount(String url) {
    final live = _liveByUrl[url];
    if (live == null || live._disposed) return 0;
    return live._capturedCount;
  }

  /// Tracked captured-emote count. Exposed for tests.
  @visibleForTesting
  static int get capturedEmoteCount => _capturedOrder.length;

  /// Seeds the captured-emote LRU without decoding. Exposed for tests.
  @visibleForTesting
  static void debugSeedCaptured(String url) => _touchCaptured(url);

  /// Captured-emote urls ordered oldest first. Exposed for tests.
  @visibleForTesting
  static List<String> get debugCapturedEmotes =>
      List<String>.unmodifiable(_capturedOrder.keys);

  /// Clears the capture registries. Exposed for tests.
  @visibleForTesting
  static void debugResetCapture() {
    _chatTouched.clear();
    _capturedOrder.clear();
  }

  /// Seeds [url]'s playback from [sourceUrl]'s current frame for in-phase swap.
  static void seedPlayback(String url, String sourceUrl) {
    if (url == sourceUrl) return;
    final live = _liveByUrl[url];
    if (live != null && !live._disposed) {
      if (live._isPlaying) {
        if (_pendingSeeds[url] == sourceUrl) _pendingSeeds.remove(url);
        if (live._seedFromUrl == sourceUrl) live._seedFromUrl = null;
        return;
      }
      if (_pendingSeeds[url] == sourceUrl && live._seedFromUrl == sourceUrl) {
        return;
      }
    }
    _storeSeed(url, sourceUrl);
    _liveByUrl[url]?.seedFrom(sourceUrl);
  }

  /// Current frame index for [url] (0 when not loaded). Exposed for tests.
  @visibleForTesting
  static int currentFrame(String url) {
    final live = _liveByUrl[url];
    if (live == null || live._disposed) return 0;
    return live.currentFrameIndex;
  }

  /// Whether [url] has a decoded frame ready. No completer creation.
  static bool hasFrames(String url) {
    final live = _liveByUrl[url];
    if (live == null || live._disposed) return false;
    final frames = live._frames;
    if (frames != null && frames.frames.isNotEmpty) return true;
    return live._hasStreamFrame;
  }

  /// Shared completer for [url], created on demand.
  static _EmoteImageCompleter? _completerFor(String url, EmoteImages images) {
    final live = _liveByUrl[url];
    if (live != null && !live._disposed) return live;
    final stream = EmoteUrlProvider(
      url,
      images: images,
    ).resolve(ImageConfiguration.empty);
    final completer = stream.completer;
    if (completer is _EmoteImageCompleter && !completer._disposed) {
      return completer;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is EmoteUrlProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'EmoteUrlProvider($url)';
}

/// Streams emote frames to listeners (one completer per URL, shared via ImageCache). Custom loop only: animated WebP, playing GIFs, frozen GIFs (still), and stray statics (still). Animated WebP streams from the engine codec; frames the engine stalls or throws on swap to the pure-Dart compositor mid-loop. Engine-routable bytes (Twitch PNG/GIF, static WebP) resolve through the stock provider at call sites and never reach this completer; if they do (probe alts, tests), they render as a single static frame with no loop, no wrapper, no extra completer.
class _EmoteImageCompleter extends ImageStreamCompleter {
  _EmoteImageCompleter({
    required this.url,
    required this.images,
    required this._engineDecode,
  }) {
    // Pick up seed queued before this completer existed.
    final queued = EmoteUrlProvider._pendingSeeds[url];
    if (queued != null && queued != url) _seedFromUrl = queued;
    _load();
  }

  final String url;
  final EmoteImages images;
  final ImageDecoderCallback _engineDecode;

  /// Materialized frames: frozen GIF, and statics. Also the captured cycle
  /// once streaming has retained every frame.
  EmoteFrameData? _frames;
  int _frameIndex = 0;

  /// Frames retained while streaming, indexed by engine frame index. Once all
  /// are present, playback hands over to [_frames] and the codec is released,
  /// so a replay costs no decode.
  List<ui.Image?> _captured = [];
  List<Duration> _capturedDurations = [];
  int _capturedCount = 0;

  /// Frames in one cycle for the active source (engine or ANMF count). Capture
  /// only completes once this many distinct frames have been retained.
  int _expectedFrameCount = 0;

  /// Streaming codec: animated WebP and playing GIFs. One live frame.
  ui.Codec? _codec;

  /// Parsed ANMF durations for streaming WebP; null uses the engine durations.
  List<Duration>? _streamDurations;
  int _streamEmitted = 0;
  bool _hasStreamFrame = false;
  bool _streamDecoding = false;
  bool _streamIsWebp = false;

  /// Last good engine frame, retained to seed the lazy fallback on a crash.
  ui.Image? _engineSeed;

  /// Lazy compositor fallback for animated WebP the engine cannot decode.
  WebpAnimInfo? _webpMeta;
  WebpEngineCompositor? _compositor;
  int _lazyIndex = 0;

  /// Fires only to request the next app frame; never emits frames itself.
  Timer? _frameTimer;
  int? _frameCallbackId;
  bool _disposed = false;

  /// Guards one engine frame decode; cancelled on detach or dispose so a
  /// stalled engine never holds a live timer.
  Timer? _streamTimeoutTimer;

  /// Ideal wall time (microseconds, wall clock) the next streamed frame is
  /// due. Each window extends the previous due instead of the emit time, so
  /// timer, vsync, and decode overhead never compounds into slow playback.
  /// Negative means unanchored: the next emission starts a fresh grid.
  int _streamDueUs = -1;

  /// Cycle position at last tick. Kept across pause/resume.
  Duration _cyclePosition = Duration.zero;

  /// True for animated GIFs (format flag).
  bool _isAnimatedGif = false;

  /// Last advanced timestamp. Null after stop (re-anchor on resume). Set during freeze (gap applied in one step).
  Duration? _shownTimestamp;

  /// Source URL for playback seed (cached smaller scale).
  String? _seedFromUrl;

  /// Bytes for [url]: the test override when set, else the owning image box.
  Future<Uint8List> _fetchBytes() {
    final override = EmoteUrlProvider.debugFetchOverride;
    if (override != null) return override(url);
    return images.bytes(url);
  }

  Future<void> _load() async {
    try {
      final bytes = await _fetchBytes();
      if (_disposed) return;
      final format = sniffEmoteFormat(bytes);
      _isAnimatedGif = format == EmoteFormat.gif;
      if (format == EmoteFormat.webp && webpIsAnimated(bytes)) {
        final meta = parseWebpAnim(bytes);
        // Animated WebP streams from the engine, scheduled by the ANMF
        // durations the engine reports wrongly. The pure-Dart compositor is a
        // crash-only fallback installed mid-loop in _onStreamAppFrame.
        await _startStreaming(
          bytes,
          durations: [
            for (final f in meta.frames) Duration(milliseconds: f.durationMs),
          ],
          isWebp: true,
        );
      } else if (format == EmoteFormat.gif) {
        await _startStreaming(bytes);
      } else {
        // Statics: one first frame, no loop. Animated emotes always stream;
        // freezing is a scheduling decision, not a load branch.
        await _loadSingleFrame(bytes);
      }
    } on Object catch (error, stack) {
      _reportQuietly(error, stack);
      // Evict on error: ImageCache keeps stale errors forever otherwise.
      PaintingBinding.instance.imageCache.evict(
        EmoteUrlProvider(url, images: images),
      );
      // Drop the seed too: a target that never loads must not pin the map.
      EmoteUrlProvider._pendingSeeds.remove(url);
    }
  }

  Future<void> _loadSingleFrame(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (_disposed) {
      buffer.dispose();
      return;
    }
    final codec = await _engineDecode(buffer);
    if (_disposed) {
      codec.dispose();
      return;
    }
    final frame = await codec.getNextFrame();
    // Clone before disposing the codec/frame so the image outlives them.
    final image = frame.image.clone();
    frame.image.dispose();
    codec.dispose();
    _frames = EmoteFrameData(frames: [image], durations: [frame.duration]);
    _emitFrame(0);
  }

  /// Opens a codec and streams its frames one at a time. [durations] overrides
  /// the engine frame durations (used for animated WebP, whose are unreliable).
  Future<void> _startStreaming(
    Uint8List bytes, {
    List<Duration>? durations,
    bool isWebp = false,
  }) async {
    final ui.Codec codec;
    try {
      codec = await _withDecodeTimeout(ui.instantiateImageCodec(bytes));
    } on Object catch (error) {
      if (_disposed) return;
      if (isWebp) {
        logDebug(
          '[emote] engine WebP open stall, lazy fallback: $url ($error)',
        );
        await _switchToLazyWebp(bytes: bytes);
        return;
      }
      rethrow;
    }
    if (_disposed) {
      codec.dispose();
      return;
    }
    _codec = codec;
    _streamDurations = durations;
    _streamIsWebp = isWebp;
    if (codec.frameCount > 0) _expectedFrameCount = codec.frameCount;
    if (isWebp &&
        durations != null &&
        codec.frameCount > 1 &&
        durations.length != codec.frameCount) {
      // Engine frame count disagrees with the ANMF count: scheduling stays on
      // ANMF durations, but the mismatch is worth seeing in logs.
      logDebug(
        '[emote] WebP frame count mismatch: $url '
        'engine=${codec.frameCount} anmf=${durations.length}',
      );
    }
    // A sequential codec cannot seek, so a queued playback seed is a no-op.
    _seedFromUrl = null;
    EmoteUrlProvider._pendingSeeds.remove(url);
    if (hasListeners) _startPlayback();
  }

  /// Notifies error listeners only. Silent details never dump through
  /// FlutterError.onError; late listeners still receive [_currentError].
  void _reportQuietly(Object error, StackTrace? stack) {
    reportError(exception: error, stack: stack, silent: true);
  }

  /// Seeds from [sourceUrl]'s current frame. Applied when frames land; ignored
  /// if already playing or streaming (a sequential codec cannot seek).
  void seedFrom(String? sourceUrl) {
    if (_disposed || sourceUrl == null || sourceUrl == url) return;
    if (_isPlaying || _codec != null || _compositor != null) return;
    _seedFromUrl = sourceUrl;
    if (_frames != null) _applySeed();
  }

  void _applySeed() {
    if (_disposed) return;
    if (_isPlaying) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    final sourceUrl = _seedFromUrl;
    if (sourceUrl == null) return;
    final source = EmoteUrlProvider._completerFor(sourceUrl, images);
    if (source == null) return;
    _seedFromUrl = null;
    EmoteUrlProvider._pendingSeeds.remove(url);
    // Copy the source's position inside its cycle so the swap happens in
    // phase (the modulo also maps it correctly when frame durations differ).
    final totalUs = frames.totalDuration.inMicroseconds;
    if (totalUs <= 0) return;
    if (source._frames != null) {
      _cyclePosition = Duration(
        microseconds: source._cyclePosition.inMicroseconds % totalUs,
      );
      _frameIndex = _frameForOffset(frames, _cyclePosition.inMicroseconds);
    } else {
      // Streaming source: mirror its frame index. Seed at the END of that
      // frame's window: the source is already part way through showing it and
      // advances on its very next tick, which keeps the swap in phase.
      final sourceIndex = source.currentFrameIndex;
      if (sourceIndex <= 0) return;
      var accumulated = 0;
      for (var i = 0; i <= sourceIndex && i < frames.durations.length; i++) {
        accumulated += _safeFrameDurationUs(frames, i);
      }
      final posUs = accumulated % totalUs;
      _cyclePosition = Duration(microseconds: posUs);
      _frameIndex = _frameForOffset(frames, posUs);
    }
  }

  /// Whether a listener is attached. Visibility proxy for capture eviction.
  bool get _visible => hasListeners;

  /// Whether the playback loop is running or a pending timer will restart it.
  bool get _isPlaying =>
      _frameCallbackId != null ||
      (_frameTimer?.isActive ?? false) ||
      _streamDecoding;

  /// Current frame index (self-driven, 0 when not loaded).
  int get currentFrameIndex {
    if (_frames != null || _hasStreamFrame) return _frameIndex;
    return 0;
  }

  /// Emits frame [index] as a clone. [setImage] clones again per listener and
  /// disposes the previous source, so the original must stay in [_frames].
  void _emitFrame(int index) {
    if (_disposed) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    _frameIndex = index;
    final ui.Image clone;
    try {
      clone = frames.frames[index].clone();
    } on StateError {
      // Frame disposed prematurely: freeze on the last good frame.
      _stopPlayback();
      return;
    }
    setImage(ImageInfo(image: clone, scale: 1.0, debugLabel: 'emote-$url'));
  }

  /// Retains a clone of a decoded frame while streaming, so a completed cycle
  /// replays from memory instead of re-decoding. Chat-surfaced urls only. The
  /// clone is a refcount share, not a pixel copy.
  void _captureFrame(int index, ui.Image image, Duration duration) {
    if (_frames != null) return;
    if (!EmoteUrlProvider._isChatUrl(url)) return;
    while (_captured.length <= index) {
      _captured.add(null);
      _capturedDurations.add(Duration.zero);
    }
    if (_captured[index] != null) return;
    _captured[index] = image.clone();
    _capturedDurations[index] = duration;
    _capturedCount++;
    EmoteUrlProvider._touchCaptured(url);
  }

  /// Switches to array playback once every captured frame is present. Returns
  /// true when it took over, so the caller stops touching the codec.
  bool _completeCaptureIfReady() {
    if (_frames != null) return false;
    final expected = _expectedFrameCount;
    if (expected <= 0) return false;
    // Require at least one full cycle to have streamed and every slot filled,
    // so a lazily grown prefix is not mistaken for a complete cycle.
    if (_streamEmitted < expected) return false;
    if (_captured.length < expected || _capturedCount < expected) return false;
    final frames = <ui.Image>[];
    final durations = <Duration>[];
    for (var i = 0; i < expected; i++) {
      final frame = _captured[i];
      if (frame == null) return false;
      frames.add(frame);
      final d = _capturedDurations[i];
      durations.add(
        d > Duration.zero ? d : const Duration(microseconds: 16000),
      );
    }
    _frames = EmoteFrameData(frames: frames, durations: durations);
    _captured.clear();
    _capturedDurations.clear();
    _capturedCount = 0;
    _expectedFrameCount = 0;
    // Release the stream and hand the elapsed-time clock the materialized set.
    _frameTimer?.cancel();
    _frameTimer = null;
    final codec = _codec;
    _codec = null;
    codec?.dispose();
    final compositor = _compositor;
    _compositor = null;
    _webpMeta = null;
    compositor?.resetStream();
    final seed = _engineSeed;
    _engineSeed = null;
    seed?.dispose();
    _streamDurations = null;
    _streamDueUs = -1;
    _seedFromUrl = null;
    EmoteUrlProvider._pendingSeeds.remove(url);
    // Continue from the frame that was just shown, not the next one: the last
    // decoded frame is already on screen, so seek to its window start.
    final totalUs = _frames!.totalDuration.inMicroseconds;
    if (totalUs > 0 && _streamEmitted > 0) {
      var posUs = 0;
      for (var i = 0; i < _streamEmitted - 1; i++) {
        posUs += _safeFrameDurationUs(_frames!, i % _frames!.frames.length);
      }
      _cyclePosition = Duration(microseconds: posUs % totalUs);
      _frameIndex = _frameForOffset(_frames!, _cyclePosition.inMicroseconds);
    }
    _shownTimestamp = null;
    _hasStreamFrame = true;
    _scheduleAppFrame();
    return true;
  }

  /// Starts the playback loop. App frames drive emission; timer requests next frame.
  void _startPlayback() {
    if (_disposed || !hasListeners) return;
    if (_isPlaying) return;
    if (_codec != null || _compositor != null) {
      // Animations off: still emit the first frame, then hold it. The tick
      // scheduler below schedules nothing while off, so playback freezes.
      if (!EmoteUrlProvider.gifsEnabled && _hasStreamFrame) return;
      _scheduleStreamAppFrame();
      return;
    }
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    if (frames.totalDuration <= Duration.zero) return;
    // Animations off: the current frame was already emitted; hold it.
    if (!EmoteUrlProvider.gifsEnabled) return;
    _scheduleAppFrame();
  }

  /// Re-evaluates after the animations toggle flips: freezes/resumes any
  /// animated emote in place. Span rebuilds (cache key includes the toggle)
  /// move frozen Twitch GIFs between the stock and custom providers; this
  /// only pauses/resumes live loops.
  void _refreshForAnimations() {
    if (_disposed) return;
    if (!_isAnimatedGif && !_streamIsWebp && _compositor == null) return;
    if (_frames == null && _codec == null && _compositor == null) return;
    if (!hasListeners) return;
    if (!EmoteUrlProvider.gifsEnabled) {
      if (_isPlaying) _stopPlayback();
    } else if (!_isPlaying) {
      _startPlayback();
    }
  }

  /// Pauses playback. Clears timestamp for re-anchor on resume; keeps cycle position.
  void _stopPlayback() {
    _frameTimer?.cancel();
    _frameTimer = null;
    final id = _frameCallbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _frameCallbackId = null;
    }
    _shownTimestamp = null;
    // Invalidate the stream grid so resume re-anchors instead of repaying
    // paused time as immediate back-to-back ticks.
    _streamDueUs = -1;
  }

  void _scheduleAppFrame() {
    if (_disposed || !hasListeners || _isPlaying) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onAppFrame,
    );
  }

  void _onAppFrame(Duration timeStamp) {
    _frameCallbackId = null;
    if (_disposed || !hasListeners) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    final totalUs = frames.totalDuration.inMicroseconds;
    if (totalUs <= 0) return;

    final shown = _shownTimestamp;
    var posUs = _cyclePosition.inMicroseconds;
    if (shown != null) {
      // Apply full elapsed gap in one step (handles VM freeze jumps).
      posUs = (posUs + (timeStamp - shown).inMicroseconds) % totalUs;
      _cyclePosition = Duration(microseconds: posUs);
      final index = _frameForOffset(frames, posUs);
      if (index != _frameIndex) {
        _emitFrame(index);
      }
    }
    _shownTimestamp = timeStamp;

    // Schedule next tick at frame window end.
    if (_frameTimer != null) return;
    var remainingUs = _frameEndUs(frames, _frameIndex) - posUs;
    if (remainingUs <= 0) {
      remainingUs = 16000; // Zero-duration guard: next vsync.
    }
    _frameTimer = Timer(Duration(microseconds: remainingUs), () {
      _frameTimer = null;
      _scheduleAppFrame();
    });
  }

  /// Requests the next app frame for the streaming loop. Never decodes here:
  /// the app-frame callback decodes, so nothing is queued while paused.
  void _scheduleStreamAppFrame() {
    if (_disposed || !hasListeners) return;
    if (_frameCallbackId != null || _streamDecoding) return;
    if (_codec == null && _compositor == null) return;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onStreamAppFrame,
    );
  }

  Future<void> _onStreamAppFrame(Duration timeStamp) async {
    _frameCallbackId = null;
    if (_disposed || !hasListeners) return;
    final codec = _codec;
    if (codec == null) {
      if (_compositor != null) await _onLazyAppFrame();
      return;
    }
    if (_streamIsWebp &&
        EmoteUrlProvider.debugWebpEngineFailAfter >= 0 &&
        _streamEmitted >= EmoteUrlProvider.debugWebpEngineFailAfter) {
      await _switchToLazyWebp();
      return;
    }
    _streamDecoding = true;
    var skipped = 0;
    while (true) {
      final ui.FrameInfo frame;
      try {
        frame = await _nextStreamFrame(codec);
      } on Object catch (error, stack) {
        _streamDecoding = false;
        if (_disposed || !hasListeners) return;
        if (_streamIsWebp) {
          // The engine stalls or throws on some frames: swap to the pure-Dart
          // compositor and keep the same playback loop.
          logDebug('[emote] engine WebP stall, lazy fallback: $url ($error)');
          await _switchToLazyWebp();
          return;
        }
        _reportQuietly(error, stack);
        _stopPlayback();
        return;
      }
      if (_disposed || _codec != codec || !hasListeners) {
        frame.image.dispose();
        _streamDecoding = false;
        return;
      }
      if (!EmoteUrlProvider.gifsEnabled && _hasStreamFrame) {
        // Toggled off mid-decode with a frame showing: drop and hold.
        frame.image.dispose();
        _streamDecoding = false;
        return;
      }
      final durations = _streamDurations;
      final duration = durations == null || durations.isEmpty
          ? frame.duration
          : durations[_streamEmitted % durations.length];
      final index = codec.frameCount > 0
          ? _streamEmitted % codec.frameCount
          : _streamEmitted;
      _captureFrame(index, frame.image, duration);
      // Drop frames whose window already elapsed so playback tracks the wall
      // clock instead of the decode rate. Bounded to one cycle per tick so a
      // background gap cannot burst-decode the whole animation.
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final windowUs = _safeStreamDuration(duration).inMicroseconds;
      final stale =
          _hasStreamFrame &&
          _streamDueUs >= 0 &&
          nowUs >= _streamDueUs + windowUs &&
          skipped < codec.frameCount;
      if (stale) {
        _streamDueUs += windowUs;
        _streamEmitted++;
        skipped++;
        frame.image.dispose();
        continue;
      }
      _frameIndex = index;
      _hasStreamFrame = true;
      if (_streamIsWebp) {
        // Retain the raw frame (one at a time) to seed a lazy fallback.
        _engineSeed?.dispose();
        _engineSeed = frame.image;
      }
      setImage(
        ImageInfo(
          image: frame.image.clone(),
          scale: 1.0,
          debugLabel: 'emote-$url',
        ),
      );
      if (!_streamIsWebp) frame.image.dispose();
      _streamEmitted++;
      _streamDecoding = false;
      // A single-frame codec emits once, like the materialized static path.
      if (codec.frameCount <= 1) {
        _codec = null;
        codec.dispose();
        return;
      }
      if (_completeCaptureIfReady()) return;
      _scheduleNextStreamTick(duration);
      return;
    }
  }

  /// Schedules the next streamed frame on the ideal grid: the window extends
  /// the previous due time, not the emit time, so per-tick overhead shifts
  /// individual frames but never slows the average rate. A negative wait
  /// fires immediately; the grid still advances by full windows.
  void _scheduleNextStreamTick(Duration window) {
    // Animations off: hold the already-emitted frame and schedule nothing.
    // Resume re-anchors from _stopPlayback's invalidation.
    if (!EmoteUrlProvider.gifsEnabled) return;
    final windowUs = _safeStreamDuration(window).inMicroseconds;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    var dueUs = _streamDueUs < 0 ? nowUs : _streamDueUs;
    // A stall longer than a few frames (backgrounding, VM freeze) leaves the
    // grid far behind wall clock; stepping through the backlog replays missed
    // frames back-to-back at super speed, so drop it and resume from now.
    if (dueUs < nowUs - 3 * windowUs) dueUs = nowUs;
    _streamDueUs = dueUs + windowUs;
    var waitUs = _streamDueUs - DateTime.now().microsecondsSinceEpoch;
    if (waitUs < 0) waitUs = 0;
    _frameTimer = Timer(Duration(microseconds: waitUs), _onStreamTick);
  }

  /// Fires when a streamed frame is due. Decodes immediately while the app is
  /// rendering, so playback tracks the wall clock instead of the render frame
  /// rate; a late tick fires again at once and catches up instead of slowing.
  /// While frames are disabled (backgrounded) it parks on a frame callback and
  /// resumes with the app, so nothing decodes offscreen.
  void _onStreamTick() {
    _frameTimer = null;
    if (_disposed || !hasListeners) return;
    if (!EmoteUrlProvider.gifsEnabled || _streamDecoding) return;
    if (!SchedulerBinding.instance.framesEnabled) {
      _scheduleStreamAppFrame();
      return;
    }
    unawaited(_onStreamAppFrame(Duration.zero));
  }

  /// Awaits an engine decode, failing after [_streamFrameTimeout]. Tracks the
  /// timeout timer so detach and dispose can cancel it; a raw `.timeout`
  /// leaves an uncancellable timer behind that outlives the completer.
  Future<T> _withDecodeTimeout<T>(Future<T> future) {
    final completer = Completer<T>();
    var timedOut = false;
    final timer = Timer(_streamFrameTimeout, () {
      timedOut = true;
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('emote decode stalled', _streamFrameTimeout),
        );
      }
    });
    _streamTimeoutTimer = timer;
    future.then(
      (value) {
        timer.cancel();
        if (identical(_streamTimeoutTimer, timer)) _streamTimeoutTimer = null;
        if (timedOut) {
          // The watchdog already failed this decode; the caller moved on, so
          // free whatever the abandoned decode produced instead of leaking it.
          _disposeLateDecode(value);
          return;
        }
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        timer.cancel();
        if (identical(_streamTimeoutTimer, timer)) _streamTimeoutTimer = null;
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return completer.future;
  }

  /// Frees a decode result the watchdog abandoned before the caller saw it.
  static void _disposeLateDecode(Object? value) {
    if (value is ui.Codec) {
      value.dispose();
    } else if (value is ui.FrameInfo) {
      value.image.dispose();
    } else if (value is ui.Image) {
      value.dispose();
    }
  }

  /// Awaits the next engine frame under the decode watchdog.
  Future<ui.FrameInfo> _nextStreamFrame(ui.Codec codec) =>
      _withDecodeTimeout(codec.getNextFrame());

  /// Cancels the engine decode watchdog so it never outlives the view.
  void _cancelStreamDecode() {
    _streamTimeoutTimer?.cancel();
    _streamTimeoutTimer = null;
  }

  /// Replaces the failing engine WebP codec with the lazy pure-Dart compositor.
  /// Re-fetches the bytes (disk cache is warm) unless the caller already holds
  /// them, so steady-state streaming holds no file bytes. The engine's last
  /// good frame seeds the accumulated canvas.
  Future<void> _switchToLazyWebp({Uint8List? bytes}) async {
    final codec = _codec;
    _codec = null;
    codec?.dispose();
    final seed = _engineSeed;
    _engineSeed = null;
    try {
      bytes ??= await _fetchBytes();
    } on Object catch (error, stack) {
      seed?.dispose();
      if (!_disposed) {
        _reportQuietly(error, stack);
        _stopPlayback();
      }
      return;
    }
    if (_disposed) {
      seed?.dispose();
      return;
    }
    final meta = parseWebpAnim(bytes);
    if (meta.frames.isEmpty) {
      seed?.dispose();
      _stopPlayback();
      return;
    }
    final compositor = WebpEngineCompositor(meta.canvasW, meta.canvasH);
    if (seed != null) compositor.seedStream(seed);
    _webpMeta = meta;
    _compositor = compositor;
    _lazyIndex = _streamEmitted % meta.frames.length;
    _expectedFrameCount = meta.frames.length;
    _scheduleStreamAppFrame();
  }

  /// Composites one lazy frame onto the retained canvas and schedules the next
  /// at the frame's ANMF duration. The canvas is retained; emitted clones own
  /// their pixels, so a later composite never invalidates a displayed frame.
  Future<void> _onLazyAppFrame() async {
    final meta = _webpMeta;
    final compositor = _compositor;
    if (meta == null || compositor == null) return;
    if (_disposed || !hasListeners) return;
    _streamDecoding = true;
    final i = _lazyIndex;
    final frameMeta = meta.frames[i];
    ui.Codec? codec;
    ui.Image? bitmap;
    try {
      // A loop wrap starts from a blank canvas: frame 0 is not a delta over the
      // previous frame. At a crash seed, i resumes where the engine stopped.
      if (i == 0) compositor.resetStream();
      final ui.Codec newCodec = await _withDecodeTimeout(
        ui.instantiateImageCodec(buildStandaloneFrameWebp(frameMeta)),
      );
      codec = newCodec;
      final hi = await _withDecodeTimeout(newCodec.getNextFrame());
      bitmap = hi.image;
      final prevMeta = i > 0 ? meta.frames[i - 1] : null;
      final out = await compositor.compositeStream(prevMeta, frameMeta, bitmap);
      bitmap.dispose();
      codec.dispose();
      bitmap = null;
      codec = null;
      if (_disposed || _compositor != compositor || !hasListeners) {
        _streamDecoding = false;
        return;
      }
      if (!EmoteUrlProvider.gifsEnabled && _hasStreamFrame) {
        // Toggled off mid-decode with a frame showing: consume the frame
        // without emitting it, mirroring the engine path's dropped decode.
        out.dispose();
        _lazyIndex = (i + 1) % meta.frames.length;
        _streamDecoding = false;
        return;
      }
      _frameIndex = i;
      _hasStreamFrame = true;
      _captureFrame(i, out, Duration(milliseconds: frameMeta.durationMs));
      setImage(
        ImageInfo(image: out.clone(), scale: 1.0, debugLabel: 'emote-$url'),
      );
    } on Object catch (error, stack) {
      bitmap?.dispose();
      codec?.dispose();
      _streamDecoding = false;
      if (!_disposed) {
        logDebug('[emote] lazy compositor failed: $url ($error)');
        _reportQuietly(error, stack);
        _stopPlayback();
      }
      return;
    }
    _streamDecoding = false;
    _lazyIndex = (i + 1) % meta.frames.length;
    if (_completeCaptureIfReady()) return;
    _scheduleNextStreamTick(Duration(milliseconds: frameMeta.durationMs));
  }

  static Duration _safeStreamDuration(Duration duration) =>
      duration > Duration.zero ? duration : const Duration(microseconds: 16000);

  /// Frame index covering [offsetUs] in the cycle.
  static int _frameForOffset(EmoteFrameData frames, int offsetUs) {
    var accumulated = 0;
    for (var i = 0; i < frames.durations.length; i++) {
      accumulated += _safeFrameDurationUs(frames, i);
      if (offsetUs < accumulated) return i;
    }
    return frames.durations.length - 1;
  }

  /// End offset (inside the cycle) of frame [index]'s duration window.
  static int _frameEndUs(EmoteFrameData frames, int index) {
    var accumulated = 0;
    for (var i = 0; i <= index; i++) {
      accumulated += _safeFrameDurationUs(frames, i);
    }
    return accumulated;
  }

  static int _safeFrameDurationUs(EmoteFrameData frames, int index) {
    final us = frames.durations[index].inMicroseconds;
    return us > 0 ? us : 16000;
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    if (_disposed || !hasListeners) return;
    // Register only once a listener attaches: a completer created but never
    // rendered (seed lookup) must not be retained by the live map.
    EmoteUrlProvider._liveByUrl[url] = this;
    if (_frames != null || _codec != null || _compositor != null) {
      // Resume animated playback when a listener returns.
      _startPlayback();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    // Drop the decode watchdog so it cannot outlive the view, then pause only
    // when the last listener leaves. An in-flight decode still resolves and
    // continues for any remaining listener.
    _cancelStreamDecode();
    super.removeListener(listener);
    if (hasListeners) return;
    _stopPlayback();
  }

  @override
  @mustCallSuper
  void onDisposed() {
    _disposed = true;
    if (EmoteUrlProvider._liveByUrl[url] == this) {
      EmoteUrlProvider._liveByUrl.remove(url);
    }
    _stopPlayback();
    _cancelStreamDecode();
    _seedFromUrl = null;
    EmoteUrlProvider._pendingSeeds.remove(url);
    final codec = _codec;
    _codec = null;
    codec?.dispose();
    final compositor = _compositor;
    _compositor = null;
    _webpMeta = null;
    compositor?.resetStream();
    final seed = _engineSeed;
    _engineSeed = null;
    seed?.dispose();
    final frames = _frames;
    _frames = null;
    if (frames != null) {
      for (final frame in frames.frames) {
        frame.dispose();
      }
    }
    for (final frame in _captured) {
      frame?.dispose();
    }
    _captured = [];
    _capturedDurations = [];
    _capturedCount = 0;
    _expectedFrameCount = 0;
    EmoteUrlProvider._capturedOrder.remove(url);
    super.onDisposed();
  }
}
