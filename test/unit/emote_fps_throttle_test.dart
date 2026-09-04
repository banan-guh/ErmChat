import 'package:ermchat/widgets/emote_image_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const _okBuild = Duration(milliseconds: 4);
const _okRaster = Duration(milliseconds: 4);
const _heavyBuild = Duration(milliseconds: 12);
const _heavyRaster = Duration(milliseconds: 12);
const _tick = Duration(seconds: 6);

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
}

/// Feeds [total] frames with [over] of them over budget (healthy first).
void _feed({required int over, required int total}) {
  for (var i = 0; i < total; i++) {
    if (i < total - over) {
      EmoteUrlProvider.debugAddPerfFrame(build: _okBuild, raster: _okRaster);
    } else {
      EmoteUrlProvider.debugAddPerfFrame(
        build: _heavyBuild,
        raster: _heavyRaster,
      );
    }
  }
}

/// Points the shared governor at [clock] and [fps], then clears its state.
void _useGovernor(_Clock clock, {double fps = 60}) {
  EmoteUrlProvider.debugSetPerfSources(
    now: clock.call,
    refreshRateFps: () => fps,
  );
  EmoteUrlProvider.debugResetPerf();
}

/// Advances past the tick boundary and feeds one tick worth of frames.
int _nextTick(_Clock clock, {required int over, required int total}) {
  clock.now = clock.now.add(_tick);
  _feed(over: over, total: total);
  return EmoteUrlProvider.debugPerfCapFor(30);
}

void main() {
  tearDown(EmoteUrlProvider.debugResetPerf);

  test('smooth frames keep the base cap', () {
    _useGovernor(_Clock());
    _feed(over: 0, total: 20);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 30);
  });

  test('mild strain trims a little on the first tick', () {
    _useGovernor(_Clock());
    _feed(over: 6, total: 20);
    // Target is ~29, within one down-step of 30.
    expect(EmoteUrlProvider.debugPerfCapFor(30), 29);

    _useGovernor(_Clock());
    _feed(over: 8, total: 20);
    // Target is ~27, within one down-step of 30.
    expect(EmoteUrlProvider.debugPerfCapFor(30), 27);
  });

  test('heavy strain rate-limits the first drop', () {
    final clock = _Clock();
    _useGovernor(clock);
    _feed(over: 16, total: 20);
    // Target is ~12 but the down-step caps the move at 30 -> 20.
    expect(EmoteUrlProvider.debugPerfCapFor(30), 20);
    // Between ticks the smoothed value holds.
    expect(EmoteUrlProvider.debugPerfCapFor(30), 20);

    // Next tick reaches the target.
    expect(_nextTick(clock, over: 16, total: 20), 12);
  });

  test('saturated strain walks to the floor over ticks', () {
    final clock = _Clock();
    _useGovernor(clock);
    _feed(over: 20, total: 20);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 20);
    expect(_nextTick(clock, over: 20, total: 20), 10);
    expect(_nextTick(clock, over: 20, total: 20), 5);
    expect(_nextTick(clock, over: 20, total: 20), 5);
  });

  test('recovery climbs slowly', () {
    final clock = _Clock();
    _useGovernor(clock);
    _feed(over: 20, total: 20);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 20);
    expect(_nextTick(clock, over: 20, total: 20), 10);
    expect(_nextTick(clock, over: 20, total: 20), 5);

    // Healthy ticks recover by at most maxUpStep (3) each.
    expect(_nextTick(clock, over: 0, total: 20), 8);
    expect(_nextTick(clock, over: 0, total: 20), 11);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 11);
  });

  test('a base cap of zero stays zero at any ratio', () {
    for (final (over, total) in [(0, 20), (6, 20), (16, 20), (20, 20)]) {
      _useGovernor(_Clock());
      _feed(over: over, total: total);
      expect(EmoteUrlProvider.debugPerfCapFor(0), 0);
    }
  });

  test('lowering the base cap applies at once', () {
    final clock = _Clock();
    _useGovernor(clock);
    _feed(over: 0, total: 20);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 30);
    expect(EmoteUrlProvider.debugPerfCapFor(10), 10);
  });

  test('a sample gap resets to healthy', () {
    final clock = _Clock();
    _useGovernor(clock);
    _feed(over: 20, total: 20);
    expect(EmoteUrlProvider.debugPerfCapFor(30), 20);

    clock.now = clock.now.add(const Duration(seconds: 6));
    expect(EmoteUrlProvider.debugPerfCapFor(30), 30);
  });

  test('a 120Hz budget turns 10ms frames strained', () {
    const build = Duration(milliseconds: 5);
    const raster = Duration(milliseconds: 5);

    var clock = _Clock();
    _useGovernor(clock, fps: 60);
    for (var i = 0; i < 20; i++) {
      EmoteUrlProvider.debugAddPerfFrame(build: build, raster: raster);
    }
    expect(EmoteUrlProvider.debugPerfCapFor(30), 30);

    clock = _Clock();
    _useGovernor(clock, fps: 120);
    for (var i = 0; i < 20; i++) {
      EmoteUrlProvider.debugAddPerfFrame(build: build, raster: raster);
    }
    expect(EmoteUrlProvider.debugPerfCapFor(30), lessThan(30));
  });

  test('missing refresh rate falls back to 60Hz', () {
    final clock = _Clock();
    for (final fps in [0.0, double.nan]) {
      _useGovernor(clock, fps: fps);
      _feed(over: 0, total: 20);
      expect(EmoteUrlProvider.debugPerfCapFor(30), 30);
    }
  });
}
