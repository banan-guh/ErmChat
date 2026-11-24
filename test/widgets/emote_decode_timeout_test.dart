import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/widgets/emote_url_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCodec implements ui.Codec {
  @override
  int get frameCount => 0;

  @override
  int get repetitionCount => 0;

  int disposeCount = 0;

  @override
  Future<ui.FrameInfo> getNextFrame() => throw UnimplementedError();

  @override
  void dispose() => disposeCount++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EmoteImages images;
  final gif = File('test/fixtures/7tv_kiss_2x.gif').readAsBytesSync();
  final webp = File('test/fixtures/7tv_uneven_2x.webp').readAsBytesSync();

  setUp(() {
    images = EmoteImages();
    EmoteUrlProvider.loadBackoff.clear();
    EmoteUrlProvider.debugFetchOverride = (_) async => gif;
    EmoteUrlProvider.debugCodecOpenOverride = null;
    EmoteUrlProvider.debugWebpEngineFailAfter = -1;
    EmoteUrlProvider.applyGifsEnabled(true);
  });

  tearDown(() {
    EmoteUrlProvider.debugFetchOverride = null;
    EmoteUrlProvider.debugCodecOpenOverride = null;
    EmoteUrlProvider.debugWebpEngineFailAfter = -1;
    EmoteUrlProvider.loadBackoff.clear();
    EmoteUrlProvider.applyGifsEnabled(true);
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.clear();
  });

  ImageStreamCompleter load(FakeAsync async, String url) {
    final provider = EmoteUrlProvider(url, images: images);
    final completer = provider.loadImage(
      provider,
      (_, {getTargetSize}) => throw UnimplementedError(),
    );
    completer.addEphemeralErrorListener((_, _) {});
    async.flushMicrotasks();
    return completer;
  }

  test('simultaneous decode deadlines share one wakeup', () {
    fakeAsync((async) {
      final pending = List.generate(8, (_) => Completer<ui.Codec>());
      var opens = 0;
      EmoteUrlProvider.debugCodecOpenOverride = (_) => pending[opens++].future;
      final urls = [for (var i = 0; i < pending.length; i++) 'gif-$i'];
      final completers = [for (final url in urls) load(async, url)];

      expect(opens, pending.length);
      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(milliseconds: 999));
      expect(pending.every((future) => !future.isCompleted), isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(async.pendingTimers, isEmpty);
      expect(urls.every(EmoteUrlProvider.loadBackoff.isBlocked), isTrue);

      final codecs = [for (var i = 0; i < pending.length; i++) _FakeCodec()];
      for (var i = 0; i < pending.length; i++) {
        pending[i].complete(codecs[i]);
      }
      async.flushMicrotasks();
      expect(codecs.every((codec) => codec.disposeCount == 1), isTrue);
      for (final completer in completers) {
        completer.maybeDispose();
      }
    });
  });

  test('staggered decode deadlines keep their exact one second delay', () {
    fakeAsync((async) {
      final first = Completer<ui.Codec>();
      final second = Completer<ui.Codec>();
      var opens = 0;
      EmoteUrlProvider.debugCodecOpenOverride = (_) =>
          [first, second][opens++].future;
      final firstCompleter = load(async, 'staggered-first');
      async.elapse(const Duration(milliseconds: 400));
      final secondCompleter = load(async, 'staggered-second');

      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(milliseconds: 600));
      expect(EmoteUrlProvider.loadBackoff.isBlocked('staggered-first'), isTrue);
      expect(
        EmoteUrlProvider.loadBackoff.isBlocked('staggered-second'),
        isFalse,
      );
      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(milliseconds: 399));
      expect(
        EmoteUrlProvider.loadBackoff.isBlocked('staggered-second'),
        isFalse,
      );
      async.elapse(const Duration(milliseconds: 1));
      expect(
        EmoteUrlProvider.loadBackoff.isBlocked('staggered-second'),
        isTrue,
      );
      expect(async.pendingTimers, isEmpty);

      first.complete(_FakeCodec());
      second.complete(_FakeCodec());
      async.flushMicrotasks();
      firstCompleter.maybeDispose();
      secondCompleter.maybeDispose();
    });
  });

  test('a completed decode cancels its deadline', () {
    fakeAsync((async) {
      final pending = Completer<ui.Codec>();
      final codec = _FakeCodec();
      EmoteUrlProvider.debugCodecOpenOverride = (_) => pending.future;
      final completer = load(async, 'completed');
      expect(async.pendingTimers, hasLength(1));

      pending.complete(codec);
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(EmoteUrlProvider.loadBackoff.isBlocked('completed'), isFalse);
      expect(codec.disposeCount, 0);

      completer.maybeDispose();
      expect(codec.disposeCount, 1);
    });
  });

  test('dispose cancels only that decode deadline', () {
    fakeAsync((async) {
      final first = Completer<ui.Codec>();
      final second = Completer<ui.Codec>();
      var opens = 0;
      EmoteUrlProvider.debugCodecOpenOverride = (_) =>
          [first, second][opens++].future;
      final firstCompleter = load(async, 'disposed-first');
      final secondCompleter = load(async, 'disposed-second');
      expect(async.pendingTimers, hasLength(1));

      firstCompleter.maybeDispose();
      expect(async.pendingTimers, hasLength(1));
      secondCompleter.maybeDispose();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(EmoteUrlProvider.loadBackoff.isBlocked('disposed-first'), isFalse);
      expect(
        EmoteUrlProvider.loadBackoff.isBlocked('disposed-second'),
        isFalse,
      );

      final firstCodec = _FakeCodec();
      final secondCodec = _FakeCodec();
      first.complete(firstCodec);
      second.complete(secondCodec);
      async.flushMicrotasks();
      expect(firstCodec.disposeCount, 1);
      expect(secondCodec.disposeCount, 1);
    });
  });

  test('a decode result arriving after timeout is disposed once', () {
    fakeAsync((async) {
      final pending = Completer<ui.Codec>();
      EmoteUrlProvider.debugCodecOpenOverride = (_) => pending.future;
      final completer = load(async, 'late');
      async.elapse(const Duration(seconds: 1));
      expect(async.pendingTimers, isEmpty);

      final codec = _FakeCodec();
      pending.complete(codec);
      async.flushMicrotasks();
      expect(codec.disposeCount, 1);
      completer.maybeDispose();
      expect(codec.disposeCount, 1);
    });
  });

  test('a decode error propagates without waiting for the deadline', () {
    fakeAsync((async) {
      final pending = Completer<ui.Codec>();
      EmoteUrlProvider.debugCodecOpenOverride = (_) => pending.future;
      final completer = load(async, 'errored');
      pending.completeError(
        StateError('codec open failed'),
        StackTrace.current,
      );
      async.flushMicrotasks();

      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 45));
      expect(
        EmoteUrlProvider.loadBackoff.isBlocked('errored'),
        isTrue,
        reason: 'a non-timeout decode failure is permanent',
      );
      completer.maybeDispose();
    });
  });

  test('a WebP open timeout still starts the lazy fallback', () {
    fakeAsync((async) {
      EmoteUrlProvider.debugFetchOverride = (_) async => webp;
      final pending = Completer<ui.Codec>();
      EmoteUrlProvider.debugCodecOpenOverride = (_) => pending.future;
      final completer = load(async, 'webp-timeout');
      final listener = ImageStreamListener((_, _) {});
      completer.addListener(listener);
      final callbacksBefore = SchedulerBinding.instance.transientCallbackCount;

      async.elapse(const Duration(seconds: 1));
      expect(async.pendingTimers, isEmpty);
      expect(
        SchedulerBinding.instance.transientCallbackCount,
        callbacksBefore + 1,
      );
      expect(EmoteUrlProvider.loadBackoff.isBlocked('webp-timeout'), isFalse);

      final codec = _FakeCodec();
      pending.complete(codec);
      async.flushMicrotasks();
      expect(codec.disposeCount, 1);
      completer.removeListener(listener);
      expect(SchedulerBinding.instance.transientCallbackCount, callbacksBefore);
      completer.maybeDispose();
    });
  });
}
