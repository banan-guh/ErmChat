import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Work counters for battery tuning, compiled in only with
/// `--dart-define=ERMCHAT_PERF=true`. Logs one `[perf]` line per [window]:
/// frames, build/raster time, timer fires by creation site, messages.
class PerfProbe {
  PerfProbe._();

  static const bool enabled = bool.fromEnvironment('ERMCHAT_PERF');
  static const Duration window = Duration(seconds: 10);

  /// One timer creation in this many records its call site.
  static const int _sampleEvery = 64;

  static int _frames = 0;
  static int _buildUs = 0;
  static int _rasterUs = 0;
  static int _timerFires = 0;
  static int _timerCreates = 0;
  static int messages = 0;
  static final Map<String, int> _sites = {};
  static final Map<String, int Function()> _gauges = {};
  static final List<Map<String, int>> _counters = [];

  /// Adds a counter map logged and cleared every window.
  static void counters(Map<String, int> map) {
    if (enabled) _counters.add(map);
  }

  /// Adds a value sampled into every log line.
  static void gauge(String name, int Function() read) {
    if (enabled) _gauges[name] = read;
  }

  /// Zone that counts timer creations and fires; null when disabled.
  static ZoneSpecification? get zoneSpec {
    if (!enabled) return null;
    return ZoneSpecification(
      createTimer: (self, parent, zone, duration, f) {
        _noteCreate();
        return parent.createTimer(zone, duration, () {
          _timerFires++;
          f();
        });
      },
      createPeriodicTimer: (self, parent, zone, period, f) {
        _noteCreate();
        return parent.createPeriodicTimer(zone, period, (t) {
          _timerFires++;
          f(t);
        });
      },
    );
  }

  static void _noteCreate() {
    if (_timerCreates++ % _sampleEvery != 0) return;
    final site = _callSite(StackTrace.current);
    _sites[site] = (_sites[site] ?? 0) + 1;
  }

  /// First app frame outside this file and the async runtime.
  static String _callSite(StackTrace stack) {
    for (final line in stack.toString().split('\n')) {
      if (!line.contains('package:ermchat/')) continue;
      if (line.contains('perf_probe.dart')) continue;
      final start = line.indexOf('package:ermchat/');
      final end = line.indexOf(')', start);
      final at = line.substring(start + 16, end < 0 ? line.length : end);
      final name = line.substring(0, start).trim();
      final fn = name.replaceFirst(RegExp(r'^#\d+\s+'), '').split(' (').first;
      return '$fn@$at';
    }
    return '<external>';
  }

  static void start() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    Timer.periodic(window, (_) => _flush());
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames++;
      _buildUs += t.buildDuration.inMicroseconds;
      _rasterUs += t.rasterDuration.inMicroseconds;
    }
  }

  static void _flush() {
    final top = _sites.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sites = top
        .take(6)
        .map((e) => '${e.key}x${e.value * _sampleEvery}')
        .join(' ');
    debugPrint(
      '[perf] frames=$_frames build=${_buildUs ~/ 1000}ms '
      'raster=${_rasterUs ~/ 1000}ms timers=$_timerFires '
      'created=$_timerCreates msgs=$messages '
      '${_gauges.entries.map((e) => '${e.key}=${e.value()}').join(' ')} '
      '${_counters.map((m) => m.toString()).join(' ')} '
      'sites: $sites',
    );
    for (final m in _counters) {
      m.clear();
    }
    _frames = _buildUs = _rasterUs = 0;
    _timerFires = _timerCreates = messages = 0;
    _sites.clear();
  }
}
