import 'dart:async';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'emote_url_provider.dart';

/// Emote frame rate while someone is using the app.
const int kActiveEmoteFps = 60;

/// Default emote frame rate when idle; 0 freezes.
const int kIdleEmoteFps = 30;

/// Active emote frame rate cap while the device is in battery saver.
const int kSaverEmoteFps = 30;

/// Drives [EmoteUrlProvider.frameRate]. Fixed at [kActiveEmoteFps], or when
/// [adaptive], [idleFps] once nobody has touched the screen for [idleAfter],
/// with battery saver capping both at [kSaverEmoteFps]. A focused text field
/// counts as use, since soft keyboard taps never reach Flutter.
class EmoteFrameRatePolicy with WidgetsBindingObserver {
  EmoteFrameRatePolicy({
    Future<bool> Function()? readSaver,
    void Function(int fps)? apply,
    this.idleAfter = const Duration(seconds: 30),
  }) : _readSaver = readSaver ?? (() => Battery().isInBatterySaveMode),
       _apply = apply ?? EmoteUrlProvider.applyFrameRate;

  final Future<bool> Function() _readSaver;
  final void Function(int fps) _apply;
  final Duration idleAfter;

  /// How often battery saver is re-read; the plugin has no change stream.
  static const _saverPoll = Duration(minutes: 1);

  bool _adaptive = false;
  bool _idle = false;
  bool _saver = false;
  bool _started = false;
  int? _fps;
  Timer? _idleTimer;
  Timer? _saverTimer;

  int get fps => _fps ?? kActiveEmoteFps;

  int _idleFps = kIdleEmoteFps;

  /// Rate used while idle or in battery saver, 0 to [kActiveEmoteFps].
  /// 0 holds the current frame until the next touch.
  int get idleFps => _idleFps;
  set idleFps(int value) {
    final clamped = value.clamp(0, kActiveEmoteFps);
    if (clamped == _idleFps) return;
    _idleFps = clamped;
    if (_started) _update();
  }

  bool get adaptive => _adaptive;
  set adaptive(bool value) {
    if (value == _adaptive) return;
    _adaptive = value;
    if (_started) _sync();
  }

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _sync();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _idleTimer?.cancel();
    _saverTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_adaptive) return;
    _touch();
    unawaited(_checkSaver());
  }

  void _onPointer(PointerEvent event) {
    if (!_adaptive) return;
    if (event is PointerDownEvent ||
        event is PointerSignalEvent ||
        event is PointerPanZoomStartEvent) {
      _touch();
    }
  }

  /// Starts or stops the idle and saver timers to match [adaptive].
  void _sync() {
    _idleTimer?.cancel();
    _saverTimer?.cancel();
    _idleTimer = _saverTimer = null;
    _idle = _saver = false;
    if (_adaptive) {
      _touch();
      _saverTimer = Timer.periodic(_saverPoll, (_) => _checkSaver());
      unawaited(_checkSaver());
    }
    _update();
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleAfter, _onIdle);
    if (_idle) {
      _idle = false;
      _update();
    }
  }

  void _onIdle() {
    _idleTimer = null;
    if (_typing) {
      _idleTimer = Timer(idleAfter, _onIdle);
      return;
    }
    _idle = true;
    _update();
  }

  bool get _typing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  Future<void> _checkSaver() async {
    bool saver;
    try {
      saver = await _readSaver();
    } on Object {
      // Unsupported platform or missing plugin: treat as off.
      saver = false;
    }
    if (!_started || !_adaptive || saver == _saver) return;
    _saver = saver;
    _update();
  }

  void _update() {
    // Battery saver lowers the ceiling, never the floor: a touch still
    // animates, and the idle rate applies only when actually idle.
    final active = _adaptive && _saver ? kSaverEmoteFps : kActiveEmoteFps;
    final fps = _adaptive && _idle ? min(_idleFps, active) : active;
    if (fps == _fps) return;
    _fps = fps;
    _apply(fps);
  }
}
