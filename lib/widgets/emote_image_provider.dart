import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../services/emote_cache_manager.dart';
import 'emote_image.dart';

const _emoteDownloadTimeout = Duration(seconds: 10);

/// Caps concurrent decodes so a burst (e.g. the emote menu opening with
/// dozens of animated WebP cells) doesn't spawn one isolate per emote at
/// once.
const int _maxConcurrentDecodes = 10;
final _DecodeSemaphore _decodeGate = _DecodeSemaphore(_maxConcurrentDecodes);

/// Fetches raw emote bytes for [url], streaming through the emote disk cache
/// when it has room and fetching straight into memory when it is full (see
/// [EmoteCacheManager]).
Future<Uint8List> fetchEmoteBytes(String url) async {
  // When there's room in the disk cache, stream through it (read cached file
  // or download + persist) exactly as before. When the cache is full (or
  // maxObjects == 0, meaning "always full" by design), skip disk entirely and
  // fetch straight into memory: the temp-file overflow path is racy under
  // concurrency (an overflow file can be evicted while another fetch is still
  // reading it) and wastes disk I/O at the exact moment we can least afford
  // it. The count read is TTL-cached, so the isFull probe is cheap.
  if (!await EmoteCacheManager().isFull()) {
    await for (final response in EmoteCacheManager().getFileStream(url)) {
      if (response is FileInfo) {
        return response.file.readAsBytes();
      }
    }
    throw StateError('no emote bytes for $url');
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

/// [ImageProvider] for emote URLs.
///
/// Keyed by [url], so the stock [ImageCache] shares one decode and one
/// playback stream between every widget rendering the same emote (and
/// dedups in-flight fetches of the same URL).
///
/// Animated WebP decodes through the reinforced decoder (native libwebp,
/// pure-Dart fallback); everything else (GIF, static WebP, PNG) falls through
/// to the stock engine codec, which handles those formats correctly.
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

  @override
  bool operator ==(Object other) =>
      other is EmoteUrlProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'EmoteUrlProvider($url)';
}

/// Streams an emote's frames to any number of listeners (one completer per
/// URL, shared via the stock [ImageCache], so every widget showing the same
/// emote renders the same frame at the same time).
///
/// Animated WebP frames come from our decoder and are played back here with a
/// [Timer] (looping forever). The playback pauses when the last listener
/// detaches and resumes from the current frame when one returns; the frames
/// stay alive while the completer is cached. Disposal (cache eviction)
/// releases every frame.
///
/// Non-animated bytes are handed to a stock [MultiFrameImageStreamCompleter]
/// (engine codec); its events are forwarded so this completer stays the only
/// one the cache and widgets ever see.
class _EmoteImageCompleter extends ImageStreamCompleter {
  _EmoteImageCompleter({required this.url, required this._engineDecode}) {
    _load();
  }

  final String url;
  final ImageDecoderCallback _engineDecode;
  EmoteFrameData? _frames;
  int _frameIndex = 0;
  Timer? _timer;
  bool _disposed = false;
  ImageStreamCompleter? _engineCompleter;
  ImageStreamListener? _engineListener;

  /// Keeps the engine completer alive while this completer is alive.
  ///
  /// The engine completer disposes itself as soon as its last listener
  /// detaches; without this handle, a widget re-attaching after a pause (cache
  /// hit for the same URL) would `addListener` on a disposed engine completer
  /// and throw. With the handle, detaching just pauses the engine (it cancels
  /// its timer and bails out of pending frame callbacks) and re-attaching
  /// resumes it.
  ImageStreamCompleterHandle? _engineHandle;

  Future<void> _load() async {
    try {
      final bytes =
          await (EmoteUrlProvider.debugFetchOverride ?? fetchEmoteBytes)(url);
      if (_disposed) return;
      if (sniffEmoteFormat(bytes) == EmoteFormat.webp &&
          webpIsAnimated(bytes)) {
        // Animated WebP: our decoder (native libwebp, pure-Dart fallback).
        final frames = await _decodeGate.withPermit(
          () =>
              (EmoteUrlProvider.debugDecodeOverride ?? decodeEmoteBytes)(bytes),
        );
        if (_disposed) return;
        _frames = frames;
        if (frames.frames.isNotEmpty) {
          _emitFrame(0);
          _scheduleNext();
        }
      } else {
        // Everything else goes through the stock engine codec.
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        if (_disposed) {
          buffer.dispose();
          return;
        }
        final inner = MultiFrameImageStreamCompleter(
          codec: _engineDecode(buffer),
          scale: 1.0,
          debugLabel: 'emote-$url',
        );
        final listener = ImageStreamListener(
          (info, syncCall) {
            // A synchronous delivery here is the engine's addListener
            // handing its current frame to a freshly attached listener. Every
            // listener already holds that frame (we forwarded it when the
            // engine first emitted it), so re-broadcasting it via setImage
            // would call setState on unrelated widgets that may be mid-build
            // in another subtree. Drop it; the frame the new listener needs
            // was already delivered synchronously by our own addListener.
            if (syncCall) {
              info.dispose();
              return;
            }
            // The engine can deliver a frame that was in flight when this
            // completer was disposed (cache eviction); setImage on a disposed
            // completer throws, so drop the handle instead.
            if (_disposed) {
              info.dispose();
              return;
            }
            setImage(info);
          },
          onError: (error, stack) {
            if (_disposed) return;
            reportError(exception: error, stack: stack);
            PaintingBinding.instance.imageCache.evict(EmoteUrlProvider(url));
          },
        );
        _engineCompleter = inner;
        _engineListener = listener;
        _engineHandle = inner.keepAlive();
        inner.addListener(listener);
      }
    } on Object catch (error, stack) {
      reportError(exception: error, stack: stack);
      // The stock ImageCache keeps an errored completer in its pending map
      // forever, so a fresh widget would keep getting the stale error with
      // no retry. Evict ourselves so the next resolve fetches again.
      PaintingBinding.instance.imageCache.evict(EmoteUrlProvider(url));
    }
  }

  /// Emits frame [index] as a clone handle (the completer's [setImage]
  /// disposes the previous handle; the refcounted backing store survives
  /// because we keep the originals in [_frames]).
  void _emitFrame(int index) {
    if (_disposed) return;
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    _frameIndex = index;
    setImage(
      ImageInfo(
        image: frames.frames[index].clone(),
        scale: 1.0,
        debugLabel: 'emote-$url',
      ),
    );
  }

  void _scheduleNext() {
    if (_disposed || !hasListeners) return;
    _timer?.cancel();
    final frames = _frames;
    if (frames == null || frames.frames.isEmpty) return;
    final next = (_frameIndex + 1) % frames.frames.length;
    final delay = frames.durations[_frameIndex];
    // Guard against zero-duration frames (a whole loop of zeros would spin
    // the timer as fast as the event loop allows).
    final safeDelay = delay > Duration.zero
        ? delay
        : const Duration(milliseconds: 16);
    _timer = Timer(safeDelay, () {
      if (_disposed || !hasListeners) return;
      _emitFrame(next);
      _scheduleNext();
    });
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    if (_disposed || !hasListeners) return;
    if (_frames != null) {
      // Resume animated playback when a listener returns.
      _scheduleNext();
    }
    final inner = _engineCompleter;
    final innerListener = _engineListener;
    if (inner != null && innerListener != null) {
      inner.addListener(innerListener);
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (hasListeners) return;
    // Pause playback and stop forwarding the engine completer so a cached
    // GIF doesn't keep decoding frames nobody is watching (the engine
    // completer disposes itself once its last listener detaches).
    _timer?.cancel();
    _timer = null;
    final inner = _engineCompleter;
    final innerListener = _engineListener;
    if (inner != null && innerListener != null) {
      inner.removeListener(innerListener);
    }
  }

  @override
  @mustCallSuper
  void onDisposed() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
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

/// Simple FIFO permit gate: [withPermit] runs [action] only once a permit is
/// free, keeping at most [maxPermits] actions in flight (used to cap
/// concurrent emote decodes so a grid burst doesn't spawn dozens of isolates
/// at once).
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
