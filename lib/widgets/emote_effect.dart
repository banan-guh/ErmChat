// FFZ and BTTV emote effects. FFZ effect values (filters, keyframes,
// timings, sizing) are adapted from FrankerFaceZ src/modules/chat/emotes.js
// and tokenizers.jsx, Copyright 2016 Dan Salvato LLC, Apache License 2.0
// (see THIRD_PARTY_LICENSES). BTTV modifiers reproduce BTTV's documented
// behavior with FFZ's motion tables; no BTTV code is included.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../emotes/emote.dart';
import 'emote_url_provider.dart';

/// One clock for every animated effect. Ticks on the shared emote grid while
/// anything listens and emotes animate, so any number of effects costs one
/// wakeup per frame.
class EmoteEffectClock extends ChangeNotifier {
  EmoteEffectClock({int Function()? nowUs}) : _nowUs = nowUs ?? _stopwatchUs {
    EmoteUrlProvider.playing.addListener(_arm);
  }

  static final instance = EmoteEffectClock();

  static final _watch = Stopwatch()..start();
  static int _stopwatchUs() => _watch.elapsedMicroseconds;

  final int Function() _nowUs;
  Timer? _tick;

  /// Seconds on the effect timeline; every effect takes its phase from it.
  double get seconds => _nowUs() / 1e6;

  /// Whether any effect is subscribed, for the leak test.
  @visibleForTesting
  bool get debugListening => hasListeners;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _arm();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _arm() {
    if (_tick != null || !hasListeners || !EmoteUrlProvider.animating) return;
    _tick = EmoteUrlProvider.runOnTick(
      1000000 ~/ EmoteUrlProvider.frameRate,
      () {
        _tick = null;
        notifyListeners();
        _arm();
      },
    );
  }

  @override
  void dispose() {
    EmoteUrlProvider.playing.removeListener(_arm);
    _tick?.cancel();
    super.dispose();
  }
}

/// Box size for an emote carrying [effects]: stretches widen it, and spins
/// and quarter turns shrink wide emotes to fit their slot. [height] is the
/// emote's normal height, the 28px reference for the pixel limits.
Size emoteEffectSize(int effects, Size size, double height) {
  var w = size.width;
  var h = size.height;
  final unit = height / 28;
  if (effects & FfzEffect.growX != 0) w = math.min(w * 2, 128 * unit);
  // BTTV wide is a fixed 112x28 box.
  if (effects & BttvEffect.wide != 0) {
    w = 4 * height;
    h = height;
  }
  void fitWidth(double limit) {
    if (w <= limit) return;
    final f = limit / w;
    w *= f;
    h *= f;
  }

  if (effects & FfzEffect.rotate != 0 && effects & FfzEffect.slide == 0) {
    fitWidth(32 * unit);
  }
  if (effects & (BttvEffect.rotateLeft | BttvEffect.rotateRight) != 0) {
    fitWidth(28 * unit);
  }
  return Size(w, h);
}

/// Whether [effects] stretch the image to fill a wider box.
bool emoteEffectStretches(int effects) =>
    effects & (FfzEffect.growX | BttvEffect.wide) != 0;

/// Applies FFZ [effects] to [child]. [slide] effects need [child] to be two
/// copies of the emote side by side, [width] each.
class EmoteEffectBox extends SingleChildRenderObjectWidget {
  const EmoteEffectBox({
    super.key,
    required this.effects,
    required this.unit,
    super.child,
  });

  final int effects;

  /// FFZ pixels to logical pixels (emote height / 28).
  final double unit;

  @override
  RenderEmoteEffect createRenderObject(BuildContext context) =>
      RenderEmoteEffect(
        effects: effects,
        unit: unit,
        animate: TickerMode.valuesOf(context).enabled,
        clock: EmoteEffectClock.instance,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderEmoteEffect renderObject,
  ) {
    renderObject
      ..effects = effects
      ..unit = unit
      ..animate = TickerMode.valuesOf(context).enabled;
  }
}

/// Paints its child through the effect's transform and color layers. A
/// repaint boundary over a retained child, so a tick re-records two layers.
class RenderEmoteEffect extends RenderProxyBox {
  RenderEmoteEffect({
    required int effects,
    required this._unit,
    required this._animate,
    required this._clock,
  }) : _plan = EmoteEffectPlan(effects);

  final EmoteEffectClock _clock;
  bool _listening = false;

  EmoteEffectPlan _plan;
  set effects(int value) {
    if (_plan.effects == value) return;
    _plan = EmoteEffectPlan(value);
    _sync();
    markNeedsPaint();
  }

  double _unit;
  set unit(double value) {
    if (_unit == value) return;
    _unit = value;
    markNeedsPaint();
  }

  bool _animate;
  set animate(bool value) {
    if (_animate == value) return;
    _animate = value;
    _sync();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => child != null;

  void _sync() {
    final want = attached && _animate && _plan.animated;
    if (want == _listening) return;
    _listening = want;
    if (want) {
      _clock.addListener(markNeedsPaint);
    } else {
      _clock.removeListener(markNeedsPaint);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sync();
  }

  @override
  void detach() {
    if (_listening) {
      _listening = false;
      _clock.removeListener(markNeedsPaint);
    }
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // Animated effects follow the animate-emotes setting, like FFZ.
    final t = EmoteUrlProvider.gifsEnabled ? _clock.seconds : null;
    final transform = _plan.transform(t, size, _unit);
    final filters = _plan.filters(t);

    void paintFiltered(PaintingContext context, Offset offset, int i) {
      if (i == filters.length) {
        final slide = t == null ? null : _plan.slideShift(t, size, _unit);
        if (slide == null) {
          context.paintChild(child, offset);
        } else {
          context.pushClipRect(
            needsCompositing,
            offset,
            Offset.zero & size,
            (context, offset) =>
                context.paintChild(child, offset.translate(slide, 0)),
          );
        }
        return;
      }
      context.pushColorFilter(
        offset,
        ColorFilter.matrix(filters[i]),
        (context, offset) => paintFiltered(context, offset, i + 1),
      );
    }

    if (transform == null) {
      paintFiltered(context, offset, 0);
    } else {
      context.pushTransform(
        needsCompositing,
        offset,
        transform,
        (context, offset) => paintFiltered(context, offset, 0),
      );
    }
  }
}

enum _Motion { none, appear, leave, inOut, rotate, shake, jam, bounce }

/// What a flag set draws, resolved once: static flips, color steps, and the
/// one transform animation that wins (later CSS animations on the same
/// property override earlier ones).
class EmoteEffectPlan {
  EmoteEffectPlan(this.effects)
    : _motion = _pickMotion(effects),
      _rainbow = effects & FfzEffect.rainbow != 0,
      _slide = effects & FfzEffect.slide != 0;

  final int effects;
  final _Motion _motion;
  final bool _rainbow;
  final bool _slide;

  bool get animated =>
      effects & (FfzEffect.animated | BttvEffect.animated) != 0;

  static _Motion _pickMotion(int f) {
    bool has(int bit) => f & bit != 0;
    if (has(FfzEffect.bounce)) return _Motion.bounce;
    if (has(FfzEffect.jam)) return _Motion.jam;
    if (has(FfzEffect.shake)) return _Motion.shake;
    if (has(FfzEffect.rotate) && !has(FfzEffect.slide)) return _Motion.rotate;
    if (has(FfzEffect.appear) && has(FfzEffect.leave)) return _Motion.inOut;
    if (has(FfzEffect.appear)) return _Motion.appear;
    if (has(FfzEffect.leave)) return _Motion.leave;
    return _Motion.none;
  }

  /// Transform at [t] seconds (null: animations off), or null for none.
  /// BTTV's applies outside FFZ's.
  Matrix4? transform(double? t, Size size, double unit) {
    final ffz = _ffzTransform(t, size, unit);
    final bttv = _bttvTransform(size);
    final shake = t != null && effects & BttvEffect.shake != 0
        ? _stepSample(_shakeFrames, _phase(t, 0.5))
        : null;
    if (bttv == null && shake == null) return ffz;
    final m = shake == null
        ? Matrix4.identity()
        : Matrix4.translationValues(shake[0] * unit, shake[1] * unit, 0);
    if (bttv != null) m.multiply(bttv);
    if (ffz != null) m.multiply(ffz);
    return m;
  }

  // Each BTTV modifier sets the same CSS transform, so the one latest in its
  // stylesheet wins instead of composing.
  Matrix4? _bttvTransform(Size size) {
    bool has(int bit) => effects & bit != 0;
    final Matrix4 m;
    if (has(BttvEffect.rotateRight)) {
      m = Matrix4.rotationZ(math.pi / 2);
    } else if (has(BttvEffect.rotateLeft)) {
      m = Matrix4.rotationZ(-math.pi / 2);
    } else if (has(BttvEffect.flipY)) {
      m = Matrix4.diagonal3Values(1, -1, 1);
    } else if (has(BttvEffect.flipX)) {
      m = Matrix4.diagonal3Values(-1, 1, 1);
    } else {
      return null;
    }
    final c = size.center(Offset.zero);
    return Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(m)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }

  Matrix4? _ffzTransform(double? t, Size size, double unit) {
    final flips = Matrix4.identity();
    var flipped = false;
    if (effects & FfzEffect.flipX != 0) {
      flips.scaleByDouble(-1, 1, 1, 1);
      flipped = true;
    }
    if (effects & FfzEffect.flipY != 0) {
      flips.scaleByDouble(1, -1, 1, 1);
      flipped = true;
    }
    final motion = t == null ? _Motion.none : _motion;
    final bounce = motion == _Motion.bounce;
    if (bounce && effects & FfzEffect.flipY != 0) {
      flips.translateByDouble(0, size.height, 0, 1);
    }
    if (motion == _Motion.none && !flipped) return null;
    final anim = motion == _Motion.none
        ? Matrix4.identity()
        : _motionAt(motion, t!, unit);
    // FFZ composes "flips anim", except bounce which is "anim flips" around
    // the bottom edge.
    final m = bounce ? (anim..multiply(flips)) : (flips..multiply(anim));
    final origin = bounce
        ? Offset(size.width / 2, size.height)
        : size.center(Offset.zero);
    return Matrix4.translationValues(origin.dx, origin.dy, 0)
      ..multiply(m)
      ..translateByDouble(-origin.dx, -origin.dy, 0, 1);
  }

  /// Color matrices to apply in order at [t] seconds. Separate steps where
  /// CSS clamps in between.
  List<List<double>> filters(double? t) => [
    if (effects & FfzEffect.hyperRed != 0) ...[
      _mul(
        _contrast(3),
        _mul(_brightness(2.2), _mul(_sepia, _brightness(0.2))),
      ),
      _saturate(8),
    ],
    if (effects & FfzEffect.cursed != 0) _cursed,
    if (_rainbow && t != null) _hueRotate(360 * _phase(t, 2)),
    // BTTV's party animation overrides its cursed filter while it runs.
    if (effects & BttvEffect.party != 0 && t != null) ...[
      _sepiaBy(0.5),
      _hueRotate(360 * _phase(t, 1.5)),
      _saturate(2.5),
    ] else if (effects & BttvEffect.cursed != 0)
      _cursed,
  ];

  /// Horizontal shift of the doubled slide strip at [t], or null.
  double? slideShift(double t, Size size, double unit) {
    if (!_slide) return null;
    final speed = 0.5 * (size.width / (32 * unit));
    return -_phase(t, speed) * size.width;
  }

  static double _phase(double t, double period) => (t % period) / period;

  static Matrix4 _motionAt(_Motion motion, double t, double unit) {
    switch (motion) {
      case _Motion.rotate:
        return Matrix4.rotationZ(2 * math.pi * _phase(t, 1.5));
      case _Motion.shake:
        final f = _sample(_shakeFrames, _phase(t, 0.1));
        return Matrix4.translationValues(f[0] * unit, f[1] * unit, 0);
      case _Motion.jam:
        final f = _sample(_jamFrames, _phase(t, 0.6));
        return Matrix4.translationValues(f[0] * unit, f[1] * unit, 0)
          ..rotateZ(f[2] * math.pi / 180);
      case _Motion.bounce:
        final f = _sample(_bounceFrames, _phase(t, 0.5));
        return Matrix4.diagonal3Values(f[0], f[1], 1);
      case _Motion.appear:
        return _appearLeave(_sample(_appearFrames, _phase(t, 3)), unit);
      case _Motion.leave:
        return _appearLeave(_sample(_leaveFrames, _phase(t, 3)), unit);
      case _Motion.inOut:
        final p = _phase(t, 6);
        return _appearLeave(
          p < 0.5
              ? _sample(_appearFrames, p * 2)
              : _sample(_leaveFrames, p * 2 - 1),
          unit,
        );
      case _Motion.none:
        return Matrix4.identity();
    }
  }

  // translateX(tx) scale(sx, sy) translateY(ty)
  static Matrix4 _appearLeave(List<double> f, double unit) =>
      Matrix4.translationValues(f[0] * unit, 0, 0)
        ..scaleByDouble(f[1], f[2], 1, 1)
        ..translateByDouble(0, f[3] * unit, 0, 1);

  /// Keyframe values at [p] under CSS `step-start`: each interval shows its
  /// end frame from the moment it begins.
  static List<double> _stepSample(List<List<double>> frames, double p) {
    final pct = p * 100;
    for (final f in frames) {
      if (f[0] > pct) return f.sublist(1);
    }
    return frames.last.sublist(1);
  }

  /// Linear interpolation of keyframe values at [p] (0..1). Frames are
  /// [percent, ...values].
  static List<double> _sample(List<List<double>> frames, double p) {
    final pct = p * 100;
    for (var i = 1; i < frames.length; i++) {
      final b = frames[i];
      if (pct > b[0]) continue;
      final a = frames[i - 1];
      final span = b[0] - a[0];
      final k = span <= 0 ? 1.0 : (pct - a[0]) / span;
      return [for (var j = 1; j < a.length; j++) a[j] + (b[j] - a[j]) * k];
    }
    return frames.last.sublist(1);
  }

  // [percent, tx, sx, sy, ty]
  static const List<List<double>> _appearFrames = [
    [0.0, -18, 0, 0, 0],
    [19.99, -18, 0, 0, 0],
    [20.0, -18, 0.1, 0.1, 0],
    [25.0, -16, 0.2, 0.2, 0.6],
    [30.0, -14, 0.3, 0.3, -4],
    [35.0, -12, 0.4, 0.4, 0.6],
    [40.0, -10, 0.5, 0.5, -4],
    [45.0, -8, 0.6, 0.6, 2],
    [50.0, -6, 0.7, 0.7, -3],
    [55.0, -4, 0.8, 0.8, 2],
    [60.0, -2, 0.9, 0.9, -3],
    [65.0, 0, 1, 1, 0],
    [100.0, 0, 1, 1, 0],
  ];

  static const List<List<double>> _leaveFrames = [
    [0.0, 0, 1, 1, 0],
    [39.99, 0, 1, 1, 0],
    [40.0, 0, -.9, .9, -3],
    [45.0, -2, -.8, .8, 2],
    [50.0, -4, -.7, .7, -3],
    [55.0, -6, -.6, .6, 2],
    [60.0, -8, -.5, .5, -4],
    [65.0, -10, -.4, .4, .6],
    [70.0, -12, -.3, .3, -4],
    [75.0, -14, -.2, .2, .6],
    [80.0, -16, -.1, .1, 0],
    [85.0, -18, -0.01, 0, 0],
    [100.0, -18, 0, 0, 0],
  ];

  // [percent, x, y]
  static const List<List<double>> _shakeFrames = [
    [0.0, 1, 1],
    [10.0, -1, -2],
    [20.0, -3, 0],
    [30.0, 3, 2],
    [40.0, 1, -1],
    [50.0, -1, 2],
    [60.0, -3, 1],
    [70.0, 3, 1],
    [80.0, -1, -1],
    [90.0, 1, 2],
    [100.0, 1, -2],
  ];

  // [percent, x, y, degrees]
  static const List<List<double>> _jamFrames = [
    [0.0, -2, -2, -6],
    [10.0, -1.5, -2, -8],
    [20.0, 1, -1.5, -8],
    [30.0, 3, 2.5, -6],
    [40.0, 3, 4, -2],
    [50.0, 2, 4, 3],
    [60.0, 1, 4, 3],
    [70.0, -0.5, 3, 2],
    [80.0, -1.25, 1, 0],
    [90.0, -1.75, -0.5, -2],
    [100.0, -2, -2, -5],
  ];

  // [percent, sx, sy]
  static const List<List<double>> _bounceFrames = [
    [0.0, 0.8, 1],
    [10.0, 0.9, 0.8],
    [20.0, 1, 0.4],
    [25.0, 1.2, 0.3],
    [25.001, -1.2, 0.3],
    [30.0, -1, 0.4],
    [40.0, -0.9, 0.8],
    [50.0, -0.8, 1],
    [60.0, -0.9, 0.8],
    [70.0, -1, 0.4],
    [75.0, -1.2, 0.3],
    [75.001, 1.2, 0.3],
    [80.0, 1, 0.4],
    [90.0, 0.9, 0.8],
    [100.0, 0.8, 1],
  ];

  // CSS filter functions as 5x4 color matrices (offsets in 0..255).
  static List<double> _rgb(List<double> m3, [double offset = 0]) => [
    m3[0], m3[1], m3[2], 0, offset, //
    m3[3], m3[4], m3[5], 0, offset,
    m3[6], m3[7], m3[8], 0, offset,
    0, 0, 0, 1, 0,
  ];

  static final _grayscale = _rgb([
    0.2126, 0.7152, 0.0722, //
    0.2126, 0.7152, 0.0722,
    0.2126, 0.7152, 0.0722,
  ]);

  static final _sepia = _rgb([
    0.393, 0.769, 0.189, //
    0.349, 0.686, 0.168,
    0.272, 0.534, 0.131,
  ]);

  static final _cursed = _mul(
    _contrast(2.5),
    _mul(_brightness(0.7), _grayscale),
  );

  /// sepia(amount): a blend of identity toward [_sepia].
  static List<double> _sepiaBy(double a) => [
    for (var i = 0; i < 20; i++) _identity[i] * (1 - a) + _sepia[i] * a,
  ];

  static final _identity = _rgb([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  static List<double> _brightness(double b) =>
      _rgb([b, 0, 0, 0, b, 0, 0, 0, b]);

  static List<double> _contrast(double c) =>
      _rgb([c, 0, 0, 0, c, 0, 0, 0, c], (0.5 - 0.5 * c) * 255);

  static List<double> _saturate(double s) => _rgb([
    0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, //
    0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s,
    0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s,
  ]);

  static List<double> _hueRotate(double degrees) {
    final r = degrees * math.pi / 180;
    final c = math.cos(r);
    final s = math.sin(r);
    return _rgb([
      0.213 + c * 0.787 - s * 0.213,
      0.715 - c * 0.715 - s * 0.715,
      0.072 - c * 0.072 + s * 0.928,
      0.213 - c * 0.213 + s * 0.143,
      0.715 + c * 0.285 + s * 0.140,
      0.072 - c * 0.072 - s * 0.283,
      0.213 - c * 0.213 - s * 0.787,
      0.715 - c * 0.715 + s * 0.715,
      0.072 + c * 0.928 + s * 0.072,
    ]);
  }

  /// [a] applied after [b].
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var v = col == 4 ? a[row * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[row * 5 + k] * b[k * 5 + col];
        }
        out[row * 5 + col] = v;
      }
    }
    return out;
  }
}
