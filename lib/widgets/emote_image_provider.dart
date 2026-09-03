import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/emote_cache_manager.dart';
import 'emote_image.dart';

const _emoteDownloadTimeout = Duration(seconds: 10);

/// Caps concurrent decodes to avoid spawning too many isolates.
const int _maxConcurrentDecodes = 10;
final _DecodeSemaphore _decodeGate = _DecodeSemaphore(_maxConcurrentDecodes);

/// Fetches emote bytes, streaming through disk cache when room.
Future<Uint8List> fetchEmoteBytes(String url) async {
  // Stream through disk cache when room; skip to memory when full (overflow path is racy).
  if (!await EmoteCacheManager().isFull()) {
    await for (final response in EmoteCacheManager().getFileStream(url)) {
      if (response is FileInfo) {
        return response.file.readAsBytes();
      }
    }
    throw StateError('no emote bytes for $url');
  }
  // Full cache: try disk cache, then network.
  final cached = await EmoteCacheManager().getCachedFile(url);
  if (cached != null) {
    return cached.readAsBytes();
  }
  final resp = await emoteFetchClient
      .get(Uri.parse(url), headers: const {'User-Agent': 'ermchat'})
      .timeout(_emoteDownloadTimeout);
  if (resp.statusCode != 200) {
    throw HttpExceptionWithStatus(
      resp.statusCode,
      'Failed to download $url',
      uri: Uri.parse(url),
    );
  }
  return resp.bodyBytes;
}

/// Adaptive perf governor: maps the fraction of frames over the refresh
/// budget to a smooth quadratic cut. Curve (base 30): r0.2->30, r0.4->27,
/// r0.6->22, r0.8->12, r1.0->5.
class _PerfGovernor {
  _PerfGovernor({DateTime Function()? now, double Function()? refreshRateFps})
    : _now = now ?? DateTime.now,
      _refreshRateFps = refreshRateFps ?? _defaultRefreshRate;

  @visibleForTesting
  static const int floorFps = 5;
  @visibleForTesting
  static const double strainGate = 0.15;

  DateTime Function() _now;
  double Function() _refreshRateFps;
  final List<_PerfSample> _samples = [];
  DateTime? _lastSampleTime;

  void addFrame({required Duration build, required Duration raster}) {
    final now = _now();
    final last = _lastSampleTime;
    if (last != null && now.difference(last) > const Duration(seconds: 2)) {
      _samples.clear();
    }
    _lastSampleTime = now;
    _samples.add(_PerfSample((build + raster).inMicroseconds, now));
    _prune(now);
  }

  void onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      addFrame(build: timing.buildDuration, raster: timing.rasterDuration);
    }
  }

  int capFor(int baseCap) {
    if (baseCap <= 0) return 0;
    final last = _lastSampleTime;
    if (last == null) return baseCap;
    final now = _now();
    if (now.difference(last) > const Duration(seconds: 2)) {
      _samples.clear();
      _lastSampleTime = null;
      return baseCap;
    }
    _prune(now);
    if (_samples.length < 10) return baseCap;
    final budgetUs = _budgetUs();
    var over = 0;
    for (final sample in _samples) {
      if (sample.costUs > budgetUs) over++;
    }
    final r = over / _samples.length;
    if (r < strainGate) return baseCap;
    final s = (r - strainGate) / (1 - strainGate);
    final capped = (baseCap * (1 - s * s)).round();
    return capped < floorFps ? floorFps : capped;
  }

  @visibleForTesting
  void reset() {
    _samples.clear();
    _lastSampleTime = null;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(const Duration(seconds: 2));
    while (_samples.isNotEmpty && _samples.first.time.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
    while (_samples.length > 60) {
      _samples.removeAt(0);
    }
  }

  int _budgetUs() {
    double fps;
    try {
      fps = _refreshRateFps();
    } catch (_) {
      fps = 60.0;
    }
    if (fps.isNaN || fps.isInfinite || fps <= 0) fps = 60.0;
    return (1000000 / fps).round();
  }

  static double _defaultRefreshRate() {
    try {
      final views = SchedulerBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return 60.0;
      final rate = views.first.display.refreshRate;
      return rate > 0 ? rate : 60.0;
    } catch (_) {
      return 60.0;
    }
  }
}

class _PerfSample {
  _PerfSample(this.costUs, this.time);

  final int costUs;
  final DateTime time;
}

/// ImageProvider for emote URLs. Keyed by [url] for shared decode/playback. Animated WebP via reinforced decoder; rest via engine codec.
class EmoteUrlProvider extends ImageProvider<EmoteUrlProvider> {
  EmoteUrlProvider(this.url);

  /// Test hooks; fall back to the production fetcher/decoder when null.
  @visibleForTesting
  static Future<Uint8List> Function(String url)? debugFetchOverride;

  @visibleForTesting
  static EmoteFrameDecoder? debugDecodeOverride;

  final String url;

  @override
  Future<EmoteUrlProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    EmoteUrlProvider key,
    ImageDecoderCallback decode,
  ) {
    return _EmoteImageCompleter(url: key.url, engineDecode: decode);
  }

  /// Seeds queued by target URL for the next completer.
  static final Map<String, String> _pendingSeeds = {};

  /// FPS cap for decoder-driven completers. 60 = uncapped, 0 = paused. Synced from prefs.
  static int fpsCap = 30;

  /// Panel emotes play at native rate regardless of [fpsCap]. Synced from prefs.
  static bool alwaysAnimatePanel = true;

  /// Whether animated GIFs play. False freezes at current frame. Synced from prefs.
  static bool gifsEnabled = true;

  /// Adaptive throttle: lowers the effective cap from measured frame strain.
  /// Synced from prefs.
  static bool adaptiveThrottle = true;

  /// Shared perf verdict driving the adaptive cap.
  static final _PerfGovernor _governor = _PerfGovernor();

  /// Whether the frame-timings callback is subscribed.
  static bool _perfSubscribed = false;

  /// Timings entry point. Re-evaluates live loops.
  static void _onPerfTimings(List<FrameTiming> timings) {
    _governor.onTimings(timings);
    refreshAdaptiveThrottle();
  }

  /// Matches the timings subscription to [adaptiveThrottle]. Never polls
  /// while the setting is off.
  static void _syncPerfSubscription() {
    if (adaptiveThrottle) {
      if (!_perfSubscribed) {
        SchedulerBinding.instance.addTimingsCallback(_onPerfTimings);
        _perfSubscribed = true;
      }
      return;
    }
    if (!_perfSubscribed) return;
    SchedulerBinding.instance.removeTimingsCallback(_onPerfTimings);
    _perfSubscribed = false;
    _governor.reset();
    refreshAdaptiveThrottle();
  }

  /// Timings subscription state. Exposed for tests.
  @visibleForTesting
  static bool get debugPerfSubscribed => _perfSubscribed;

  /// Resets the shared perf governor. Exposed for tests.
  @visibleForTesting
  static void debugResetPerf() => _governor.reset();

  /// Overrides the governor clock/budget. Exposed for tests.
  @visibleForTesting
  static void debugSetPerfSources({
    DateTime Function()? now,
    double Function()? refreshRateFps,
  }) {
    if (now != null) _governor._now = now;
    if (refreshRateFps != null) _governor._refreshRateFps = refreshRateFps;
  }

  /// Feeds one frame to the shared governor. Exposed for tests.
  @visibleForTesting
  static void debugAddPerfFrame({
    required Duration build,
    required Duration raster,
  }) => _governor.addFrame(build: build, raster: raster);

  /// Governor cap for [baseCap]. Exposed for tests.
  @visibleForTesting
  static int debugPerfCapFor(int baseCap) => _governor.capFor(baseCap);

  /// Toggles adaptive throttle and re-evaluates all live completers.
  static void applyAdaptiveThrottle(bool enabled) {
    adaptiveThrottle = enabled;
    _syncPerfSubscription();
    refreshAdaptiveThrottle();
  }

  /// Re-evaluates all live completers after cap input changes.
  static void refreshAdaptiveThrottle() {
    for (final completer in List.of(_liveByUrl.values)) {
      completer._refreshForFpsCap();
    }
  }

  /// Total listeners on playback-capable completers (animated copies on screen).
  static int get animatedListenerCount => _liveByUrl.values.fold(
    0,
    (total, completer) =>
        total + (completer._playbackCapable ? completer._listenerCount : 0),
  );

  /// Sets FPS cap (0..60) and updates all live completers.
  static void applyFpsCap(int cap) {
    fpsCap = cap.clamp(0, 60);
    for (final completer in List.of(_liveByUrl.values)) {
      completer._refreshForFpsCap();
    }
  }

  /// Toggles GIF animation, freezing/resuming live completers.
  static void applyGifsEnabled(bool enabled) {
    gifsEnabled = enabled;
    for (final completer in List.of(_liveByUrl.values)) {
      completer._refreshForGifs();
    }
  }

  /// Registers [url] as uncapped (creates completer on demand). No-op if unresolvable.
  static void addUncapped(String url) {
    _completerFor(url)?.addUncappedListener();
  }

  /// Removes an uncapped registration. Only affects live completers.
  static void removeUncapped(String url) {
    _liveByUrl[url]?.removeUncappedListener();
  }

  /// Rounds wake target up to grid multiple for shared wake instants. Exposed for tests.
  @visibleForTesting
  static int alignWakeUsToGrid(int targetUs, int gridUs) {
    if (gridUs <= 0) return targetUs;
    return ((targetUs + gridUs - 1) ~/ gridUs) * gridUs;
  }

  /// Live completers by URL. Authoritative source (ImageCache may drop pending completers).
  static final Map<String, _EmoteImageCompleter> _liveByUrl = {};

  /// Seeds [url]'s playback from [sourceUrl]'s current frame for in-phase swap.
  static void seedPlayback(String url, String sourceUrl) {
    _pendingSeeds[url] = sourceUrl;
    _completerFor(url)?.seedFrom(sourceUrl);
  }

  /// Current frame index for [url] (0 when not loaded). Exposed for tests.
  @visibleForTesting
  static int currentFrame(String url) =>
      _completerFor(url)?.currentFrameIndex ?? 0;

  /// Effective FPS cap for [url] (-1 when absent). Exposed for tests.
  static int debugEffectiveCap(String url) =>
      _liveByUrl[url]?._effectiveFpsCap ?? -1;

  /// Shared completer for [url], created on demand.
  static _EmoteImageCompleter? _completerFor(String url) {
    final live = _liveByUrl[url];
    if (live != null && !live._disposed) return live;
    final stream = EmoteUrlProvider(url).resolve(ImageConfiguration.empty);
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

/// Streams emote frames to listeners (one completer per URL, shared via ImageCache). Animated WebP self-driven; non-animated forwarded from engine completer.
class _EmoteImageCompleter extends ImageStreamCompleter {
  _EmoteImageCompleter({required this.url, required this._engineDecode}) {
    // Pick up seed queued before this completer existed.
    final queued = EmoteUrlProvider._pendingSeeds[url];
    if (queued != null && queued != url) _seedFromUrl = queued;
    EmoteUrlProvider._liveByUrl[url] = this;
    _load();
  }

  final String url;
  final ImageDecoderCallback _engineDecode;
  EmoteFrameData? _frames;
  int _frameIndex = 0;

  /// Fires only to request the next app frame; never emits frames itself.
  Timer? _frameTimer;
  int? _frameCallbackId;
  bool _disposed = false;

  /// Cycle position at last tick. Kept across pause/resume.
  Duration _cyclePosition = Duration.zero;

  /// Count of uncapped listeners. While > 0, plays at native rate regardless of FPS cap.
  int _uncappedCount = 0;

  /// Listener count (telemetry only; the governor reads frame strain).
  int _listenerCount = 0;

  /// Whether this completer has a throttling-worthy animation (multi-frame with real cycle).
  bool _playbackCapable = false;

  /// True for animated GIFs; allows freeze/resume via gifs toggle.
  bool _isAnimatedGif = false;

  /// Last advanced timestamp. Null after stop (re-anchor on resume). Set during freeze (gap applied in one step).
  Duration? _shownTimestamp;
  ImageStreamCompleter? _engineCompleter;
  ImageStreamListener? _engineListener;

  /// Engine codec; mirrors private frame counter via [_engineFramesDelivered].
  ui.Codec? _engineCodec;

  /// Forwarded frame count (sync frames dropped).
  int _engineFramesDelivered = 0;

  /// Source URL for playback seed (cached smaller scale).
  String? _seedFromUrl;

  /// Keeps engine completer alive. Prevents addListener-on-disposed throw after cache hit.
  ImageStreamCompleterHandle? _engineHandle;

  Future<void> _load() async {
    try {
      final bytes =
          await (EmoteUrlProvider.debugFetchOverride ?? fetchEmoteBytes)(url);
      if (_disposed) return;
      final format = sniffEmoteFormat(bytes);
      final isWebpAnim = format == EmoteFormat.webp && webpIsAnimated(bytes);
      final seeded = _seedFromUrl != null;
      final gifAnimated =
          format == EmoteFormat.gif && EmoteUrlProvider.gifsEnabled;
      _isAnimatedGif = format == EmoteFormat.gif;
      if (isWebpAnim || (gifAnimated && seeded)) {
        // Animated WebP: our decoder. Animated GIF with seed: also our decoder (needs our clock).
        final frames = await _decodeGate.withPermit(
          () =>
              (EmoteUrlProvider.debugDecodeOverride ?? decodeEmoteBytes)(bytes),
        );
        if (_disposed) return;
        _frames = frames;
        if (frames.frames.isNotEmpty) {
          _applySeed();
          _emitFrame(_frameIndex);
          _startPlayback();
        }
        // Telemetry now that playback is confirmed.
        _playbackCapable =
            frames.frames.length > 1 && frames.totalDuration > Duration.zero;
      } else if (format == EmoteFormat.gif && !EmoteUrlProvider.gifsEnabled) {
        // Frozen GIF: decode only the first frame so it shows as a still image.
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
        // Clone before disposing the codec so the image outlives it.
        final image = frame.image.clone();
        codec.dispose();
        _frames = EmoteFrameData(frames: [image], durations: [frame.duration]);
        _emitFrame(0);
      } else {
        // Everything else goes through the stock engine codec.
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        if (_disposed) {
          buffer.dispose();
          return;
        }
        final codecFuture = _engineDecode(buffer);
        codecFuture.then(
          (codec) {
            if (!_disposed) {
              _engineCodec = codec;
              // Engine-path animations are GIFs only (telemetry).
              _playbackCapable = codec.frameCount > 1;
            }
          },
          onError: (_) {
            // The engine completer reports the error itself.
          },
        );
        final inner = MultiFrameImageStreamCompleter(
          codec: codecFuture,
          scale: 1.0,
          debugLabel: 'emote-$url',
        );
        final listener = ImageStreamListener(
          (info, syncCall) {
            // The framework hands each listener an owned ImageInfo clone.
            // setImage takes ownership of `info`; dispose on early returns.
            if (_disposed) {
              info.dispose();
              return;
            }
            // Synchronous re-delivery on re-attach: the inner completer's
            // _currentImage already holds this frame and re-pushes it to new
            // listeners. Rebroadcasting here would setState during build.
            if (syncCall) {
              info.dispose();
              return;
            }
            _engineFramesDelivered++;
            setImage(info);
          },
          onError: (error, stack) {
            if (_disposed) return;
            _reportQuietly(error, stack);
            PaintingBinding.instance.imageCache.evict(EmoteUrlProvider(url));
          },
        );
        _engineCompleter = inner;
        _engineListener = listener;
        _engineHandle = inner.keepAlive();
        inner.addListener(listener);
      }
    } on Object catch (error, stack) {
      _reportQuietly(error, stack);
      // Evict on error: ImageCache keeps stale errors forever otherwise.
      PaintingBinding.instance.imageCache.evict(EmoteUrlProvider(url));
    }
  }

  /// Notifies error listeners only. Silent details never dump through
  /// FlutterError.onError; late listeners still receive [_currentError].
  void _reportQuietly(Object error, StackTrace? stack) {
    reportError(exception: error, stack: stack, silent: true);
  }

  /// Seeds from [sourceUrl]'s current frame. Applied when frames land; ignored if already playing.
  void seedFrom(String? sourceUrl) {
    if (_disposed || sourceUrl == null || sourceUrl == url) return;
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
    final source = EmoteUrlProvider._completerFor(sourceUrl);
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
      // Engine-path source: mirror its frame index. Seed
      // at the END of that frame's window: the engine source is already part
      // way through showing it and advances on its very next tick, and this
      // keeps the swap in phase with it.
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

  /// Whether the playback loop is running or a pending timer will restart it.
  bool get _isPlaying =>
      _frameCallbackId != null || (_frameTimer?.isActive ?? false);

  /// Current frame index (self-driven or engine-mirrored, 0 when not loaded).
  int get currentFrameIndex {
    final frames = _frames;
    if (frames != null) return _frameIndex;
    final codec = _engineCodec;
    final delivered = _engineFramesDelivered;
    if (codec == null || delivered == 0 || codec.frameCount == 0) return 0;
    return (delivered - 1) % codec.frameCount;
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

  /// Starts the playback loop. App frames drive emission; timer requests next frame.
  void _startPlayback() {
    // Lazy subscribe so startup works regardless of prefs-sync order.
    EmoteUrlProvider._syncPerfSubscription();
    if (_disposed || !hasListeners) return;
    if (_isPlaying) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    if (frames.totalDuration <= Duration.zero) return;
    if (_effectiveFpsCap == 0) return; // Paused by the FPS-cap setting.
    if (_isAnimatedGif && !EmoteUrlProvider.gifsEnabled) return; // Frozen GIF.
    _scheduleAppFrame();
  }

  /// Effective FPS cap: panel-bypassed = full rate; otherwise the user's cap
  /// with the perf governor when adaptiveThrottle is on.
  int get _effectiveFpsCap {
    if (_uncappedCount > 0) return 60;
    if (!EmoteUrlProvider.adaptiveThrottle) return EmoteUrlProvider.fpsCap;
    return EmoteUrlProvider._governor.capFor(EmoteUrlProvider.fpsCap);
  }

  /// Wake alignment grid in microseconds. 0 or uncapped = no alignment.
  int get _wakeGridUs {
    final cap = _effectiveFpsCap;
    if (cap <= 0 || cap >= 60) return 0;
    return 1000000 ~/ cap;
  }

  /// Re-evaluates loop after cap/panel change: stop at pause, restart when unpaused.
  void _refreshForFpsCap() {
    if (_disposed || !hasListeners) return;
    if (_frames == null) return;
    if (_effectiveFpsCap == 0) {
      if (_isPlaying) _stopPlayback();
    } else if (!_isPlaying) {
      _startPlayback();
    }
  }

  /// Re-evaluates after gifsEnabled flip: freezes/resumes animated GIFs only.
  void _refreshForGifs() {
    if (_disposed || !_isAnimatedGif) return;
    final inner = _engineCompleter;
    final listener = _engineListener;
    if (inner != null && listener != null) {
      // Engine GIF: detach freezes, re-attach resumes. Sync delivery dropped.
      if (!EmoteUrlProvider.gifsEnabled) {
        inner.removeListener(listener);
      } else if (hasListeners) {
        inner.addListener(listener);
      }
      return;
    }
    if (_frames == null || !hasListeners) return;
    if (!EmoteUrlProvider.gifsEnabled || _effectiveFpsCap == 0) {
      if (_isPlaying) _stopPlayback();
    } else if (!_isPlaying) {
      _startPlayback();
    }
  }

  /// Registers/unregisters an uncapped listener. Syncs loop state.
  void addUncappedListener() {
    _uncappedCount++;
    _refreshForFpsCap();
  }

  void removeUncappedListener() {
    if (_uncappedCount > 0) _uncappedCount--;
    _refreshForFpsCap();
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

    // Schedule next tick at frame window end, aligned to FPS-cap grid.
    if (_frameTimer != null) return;
    final gridUs = _wakeGridUs;
    if (_effectiveFpsCap == 0) return; // Paused: stop the loop.
    var remainingUs = _frameEndUs(frames, _frameIndex) - posUs;
    if (remainingUs <= 0) {
      remainingUs = 16000; // Zero-duration guard: next vsync.
    }
    if (gridUs > 0) {
      final wakeTargetUs = timeStamp.inMicroseconds + remainingUs;
      remainingUs =
          EmoteUrlProvider.alignWakeUsToGrid(wakeTargetUs, gridUs) -
          timeStamp.inMicroseconds;
      if (remainingUs <= 0) remainingUs = gridUs;
    }
    _frameTimer = Timer(Duration(microseconds: remainingUs), () {
      _frameTimer = null;
      _scheduleAppFrame();
    });
  }

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
    _listenerCount++;
    _noteAdaptiveInput();
    if (_disposed || !hasListeners) return;
    if (_frames != null) {
      // Resume animated playback when a listener returns.
      _startPlayback();
    }
    final inner = _engineCompleter;
    final innerListener = _engineListener;
    if (inner != null && innerListener != null) {
      // A frozen GIF (animate-gifs off) must not restart via re-attach.
      if (!_isAnimatedGif || EmoteUrlProvider.gifsEnabled) {
        inner.addListener(innerListener);
      }
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (_listenerCount > 0) _listenerCount--;
    _noteAdaptiveInput();
    if (hasListeners) return;
    // Pause playback and detach engine completer (stops decoding idle frames).
    _stopPlayback();
    final inner = _engineCompleter;
    final innerListener = _engineListener;
    if (inner != null && innerListener != null) {
      inner.removeListener(innerListener);
    }
  }

  /// Telemetry hook. The governor reacts to frame strain, so listener
  /// changes no longer re-evaluate loops.
  void _noteAdaptiveInput() {}

  @override
  @mustCallSuper
  void onDisposed() {
    _disposed = true;
    if (EmoteUrlProvider._liveByUrl[url] == this) {
      EmoteUrlProvider._liveByUrl.remove(url);
    }
    _playbackCapable = false;
    _stopPlayback();
    final inner = _engineCompleter;
    final innerListener = _engineListener;
    if (inner != null && innerListener != null) {
      inner.removeListener(innerListener);
    }
    // Releases the engine completer now that no one can re-attach to it.
    _engineHandle?.dispose();
    _engineHandle = null;
    _engineCompleter = null;
    _engineListener = null;
    _engineCodec = null;
    _seedFromUrl = null;
    final frames = _frames;
    _frames = null;
    if (frames != null) {
      for (final frame in frames.frames) {
        frame.dispose();
      }
    }
    super.onDisposed();
  }
}

/// FIFO permit gate: runs [action] only when a permit is free. Caps concurrent decodes.
class _DecodeSemaphore {
  _DecodeSemaphore(this.maxPermits) : _permits = maxPermits;

  final int maxPermits;
  int _permits;
  final List<Completer<void>> _waiters = [];

  Future<T> withPermit<T>(Future<T> Function() action) async {
    if (_permits > 0) {
      _permits--;
    } else {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _permits++;
      }
    }
  }
}
