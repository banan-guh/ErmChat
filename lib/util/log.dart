import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Whether app-level debug logging is enabled.
///
/// Tests set this to false (via `test/flutter_test_config.dart`) to keep the
/// test console readable. The Flutter test binding forces [debugPrint] to a
/// synchronous console printer, so silencing has to happen at this hook.
bool debugLogEnabled = true;

/// App logging hook. Call this instead of [debugPrint] so the test suite can
/// silence chat-pipeline noise (IRC joins, badge fetch failures, reconnect
/// diagnostics) without touching the binding's [debugPrint] plumbing.
void logDebug(String? message, {int? wrapWidth}) {
  if (debugLogEnabled) {
    debugPrint(message, wrapWidth: wrapWidth);
  }
}

/// Flight recorder for diagnosing erratic freezes.
///
/// Keeps a bounded in-memory ring buffer of timestamped records, mirrors each
/// one to the console via [logDebug], and periodically flushes the buffer to
/// `perf_log.txt` in the app documents directory. On startup the previous
/// session's file is rotated to `perf_log.prev.txt`, so a freeze that ends in
/// a force-kill can still be diagnosed after relaunch (open Dev settings >
/// Performance log).
///
/// All file IO is best-effort: any failure silently degrades to in-memory
/// only. Logging must never crash the app or distort timings.
class PerfLog {
  PerfLog._();
  static final PerfLog I = PerfLog._();

  static const int maxEntries = 1000;
  static const Duration flushInterval = Duration(seconds: 2);

  final List<String> _entries = <String>[];
  File? _file;
  File? _prevFile;
  Timer? _flushTimer;
  bool _dirty = false;

  /// Rotates the previous session's log aside and prepares a fresh file.
  /// Safe to call multiple times; only the first call does work.
  Future<void> init() async {
    if (_file != null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sep = Platform.pathSeparator;
      _file = File('${dir.path}${sep}perf_log.txt');
      _prevFile = File('${dir.path}${sep}perf_log.prev.txt');
      if (await _file!.exists()) {
        try {
          await _prevFile!.delete();
        } catch (_) {}
        await _file!.rename(_prevFile!.path);
      }
      record('PERF', 'session start');
    } catch (_) {
      // No documents directory (tests, web): stay in-memory only.
      _file = null;
      _prevFile = null;
    }
  }

  void record(String tag, String message) {
    final line =
        '${DateTime.now().toIso8601String()} [$tag] $message';
    _entries.add(line);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    logDebug('[perf] $tag $message');
    _dirty = true;
    _scheduleFlush();
  }

  List<String> entries() => List.unmodifiable(_entries);

  /// Contents of the previous session's log, or null when unavailable.
  Future<String?> readPreviousSession() async {
    final f = _prevFile;
    if (f == null) return null;
    try {
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  void _scheduleFlush() {
    if (_file == null || _flushTimer != null) return;
    _flushTimer = Timer(flushInterval, () async {
      _flushTimer = null;
      final f = _file;
      if (f == null || !_dirty) return;
      _dirty = false;
      try {
        await f.writeAsString('${_entries.join('\n')}\n');
      } catch (_) {}
    });
  }
}
