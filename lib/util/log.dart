import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Whether debug logging is enabled. Tests set this to false.
bool debugLogEnabled = !kReleaseMode;

/// App logging hook. Use instead of [debugPrint] so tests can silence noise.
void logDebug(String? message, {int? wrapWidth}) {
  if (debugLogEnabled) {
    debugPrint(message, wrapWidth: wrapWidth);
  }
}

/// Recent app events, printed alongside any frame that stalls so a hitch
/// names its likely cause. A note is a list append; nothing prints unless
/// a frame runs long. Times share [Timeline.now]'s clock with frame timings.
class JankLog {
  JankLog._();

  /// Frames at least this long are reported.
  static const int stallMs = 50;

  /// Notes this old at the frame's start are left out.
  static const int _windowUs = 3000000;
  static const int _keep = 32;
  static final ListQueue<(int, String)> _notes = ListQueue();

  /// Records [event] for the next stall report.
  static void note(String event) {
    if (!debugLogEnabled) return;
    _notes.addLast((Timeline.now, event));
    if (_notes.length > _keep) _notes.removeFirst();
  }

  /// Notes printed per stall, the latest.
  static const int _shown = 8;

  /// Logs a stalled frame that started at [startUs] and ended at [endUs],
  /// with the notes from just before it to its end. [waitMs] is the time
  /// from vsync to the build starting: the UI thread busy outside the frame.
  static void stall({
    required int startUs,
    required int endUs,
    required int waitMs,
    required int buildMs,
    required int rasterMs,
    String extra = '',
  }) {
    final all = [
      for (final (at, event) in _notes)
        if (at >= startUs - _windowUs && at <= endUs)
          '${((at - startUs) / 1000).round()}ms $event',
    ];
    final recent = all.length > _shown ? all.sublist(all.length - _shown) : all;
    logDebug(
      '[jank] ${((endUs - startUs) / 1000).round()}ms wait=${waitMs}ms '
      'build=${buildMs}ms raster=${rasterMs}ms$extra | '
      '${recent.isEmpty ? 'no recent events' : recent.join(', ')}',
    );
  }
}

/// App event log, kept on disk across sessions so a rare bug leaves a trail
/// (Dev settings > App log). Each session appends to its own files under
/// `logs/`, and the oldest files go once the folder passes [maxBytes].
class AppLog {
  AppLog._();
  static final AppLog I = AppLog._();

  @visibleForTesting
  AppLog.test();

  /// Disk budget across all sessions.
  static const int maxBytes = 8 << 20;

  /// A session continues in a new file past this size, so pruning can drop
  /// the old half of a long session instead of all of it.
  static const int maxFileBytes = 1 << 20;

  /// Characters [copyText] stops at. Larger clipboard writes can fail on
  /// Android, and most paste targets truncate well before this.
  static const int copyLimit = 100000;

  static const Duration flushInterval = Duration(seconds: 2);

  final List<String> _pending = <String>[];
  Directory? _dir;
  File? _file;
  String _session = '';
  int _part = 0;
  int _fileBytes = 0;
  Timer? _flushTimer;
  Future<void> _writing = Future<void>.value();

  /// Opens this session's file and prunes old sessions. Lines recorded
  /// before it are kept and written on the first flush. Idempotent.
  Future<void> init({Directory? dir}) async {
    if (_dir != null) return;
    try {
      final base = dir ?? await getApplicationDocumentsDirectory();
      final logs = Directory('${base.path}${Platform.pathSeparator}logs');
      await logs.create(recursive: true);
      for (final name in const ['perf_log.txt', 'perf_log.prev.txt']) {
        final old = File('${base.path}${Platform.pathSeparator}$name');
        if (await old.exists()) await old.delete();
      }
      _dir = logs;
      _session = DateTime.now().millisecondsSinceEpoch.toString();
      _file = _partFile();
      await _prune();
    } catch (_) {
      // No documents directory (tests, web): stay in memory only.
      _dir = null;
      _file = null;
    }
    record('LOG', 'session start');
  }

  File _partFile() => File(
    '${_dir!.path}${Platform.pathSeparator}'
    '$_session-${_part.toString().padLeft(3, '0')}.txt',
  );

  /// Appends one entry. Continuation lines of a multi-line [message] are
  /// indented, which is how [read] tells entries apart.
  void record(String tag, String message) {
    final body = message.replaceAll('\n', '\n    ');
    _pending.add('${DateTime.now().toIso8601String()} [$tag] $body');
    logDebug('[$tag] $message');
    if (_file == null) {
      // Memory only until init, or for good without a documents directory.
      if (_pending.length > 2000) _pending.removeAt(0);
      return;
    }
    _flushTimer ??= Timer(flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Writes pending entries. Writes run one at a time, in order.
  Future<void> flush() => _writing = _writing.then((_) => _write());

  Future<void> _write() async {
    final f = _file;
    if (f == null || _pending.isEmpty) return;
    final text = '${_pending.join('\n')}\n';
    _pending.clear();
    try {
      await f.writeAsString(text, mode: FileMode.append, flush: true);
      _fileBytes += utf8.encode(text).length;
      if (_fileBytes > maxFileBytes) {
        _part++;
        _fileBytes = 0;
        _file = _partFile();
        await _prune();
      }
    } catch (_) {
      // Disk full or the folder gone: these lines are lost, later ones retry.
    }
  }

  /// Deletes the oldest files until the folder fits [maxBytes]. File names
  /// start with the session's epoch milliseconds, so name order is age order.
  Future<void> _prune() async {
    final files = await _files();
    var total = 0;
    for (final f in files.reversed) {
      total += await f.length();
      if (total > maxBytes && f.path != _file?.path) await f.delete();
    }
  }

  Future<List<File>> _files() async {
    final dir = _dir;
    if (dir == null) return [];
    final files = [
      await for (final e in dir.list())
        if (e is File && e.path.endsWith('.txt')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Every entry on disk plus any not yet written, newest first.
  Future<List<String>> read() async {
    await flush();
    final lines = <String>[];
    for (final f in await _files()) {
      try {
        lines.addAll(await f.readAsLines());
      } catch (_) {}
    }
    lines.addAll(_pending.expand((e) => e.split('\n')));
    final entries = <String>[];
    for (final line in lines) {
      if (line.isEmpty) continue;
      if (line.startsWith(' ') && entries.isNotEmpty) {
        entries.last = '${entries.last}\n$line';
      } else {
        entries.add(line);
      }
    }
    return entries.reversed.toList();
  }

  /// [newestFirst] entries joined until [limit] characters, newest first,
  /// and how many fit.
  static (String, int) copyText(
    List<String> newestFirst, {
    int limit = copyLimit,
  }) {
    final out = StringBuffer();
    var count = 0;
    for (final entry in newestFirst) {
      if (out.length + entry.length + 1 > limit) break;
      out.writeln(entry);
      count++;
    }
    return (out.toString(), count);
  }
}
