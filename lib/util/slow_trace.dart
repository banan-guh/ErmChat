import 'log.dart';

/// Times the stages of work that should stay fast and logs one line only when
/// the total passes [limitMs]. A normal run says nothing; a slow one names the
/// stage that took the time, so a stall explains itself.
class SlowTrace {
  SlowTrace(this.name, {this.limitMs = 300});

  final String name;
  final int limitMs;
  final Stopwatch _sw = Stopwatch()..start();
  final List<String> _stages = [];
  int _lastMs = 0;

  /// Records the time since the previous mark as [stage].
  void mark(String stage, [Object? detail]) {
    final now = _sw.elapsedMilliseconds;
    _stages.add('$stage ${now - _lastMs}ms${detail == null ? '' : ' $detail'}');
    _lastMs = now;
  }

  /// Logs the total and its stages when the total reached [limitMs]. Returns
  /// the total milliseconds.
  int end([Object? detail]) {
    final total = _sw.elapsedMilliseconds;
    if (total >= limitMs) {
      logDebug(
        '[slow] $name ${total}ms'
        '${detail == null ? '' : ' $detail'}'
        ' | ${_stages.join(', ')}',
        // Severe stalls reach the on-disk log a bug report carries.
        persist: total >= 2000,
      );
    }
    return total;
  }
}
