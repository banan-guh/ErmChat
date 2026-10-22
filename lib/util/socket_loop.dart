import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connectivity.dart';
import 'log.dart';

/// How one connection attempt ended.
enum SocketEnd {
  /// The socket closed, failed or never opened: back off, then retry.
  dropped,

  /// The server asked for a new connection: retry at once.
  reconnectNow,

  /// Retrying cannot help (a dead token, a refusing close code): stop.
  fatal,
}

/// Keeps one socket alive. Each attempt opens the socket and serves it until
/// it dies; the loop then backs off and tries again, so connecting,
/// serving and waiting are where the loop is, never flags to keep in sync.
///
/// [start] replaces any run in flight and [stop] ends it, so exactly one run
/// can ever open a socket. Being offline never stops a retry: coming back
/// online wakes the wait and starts the count over. After [maxAttempts]
/// retries in a row the loop stops retrying until the network returns or
/// the owner restarts it.
class SocketLoop {
  SocketLoop({
    required this.name,
    required this.attempt,
    required this.backoff,
    this.maxAttempts,
    this.connectivity,
    this.connectTimeout = const Duration(seconds: 10),
  });

  /// Log prefix.
  final String name;

  /// Opens the socket, serves it until it dies, and says how it ended.
  /// Throwing counts as [SocketEnd.dropped].
  final Future<SocketEnd> Function(SocketRun run) attempt;

  /// The wait before retry number `failures`, counted from 1.
  final Duration Function(int failures) backoff;

  /// Retries in a row before the loop waits for the network instead.
  /// Null retries forever.
  final int? maxAttempts;

  final ConnectivityService? connectivity;
  final Duration connectTimeout;

  SocketRun? _run;
  int _failures = 0;
  VoidCallback? _connectivityListener;
  bool _wasOnline = true;

  /// Failed attempts since the last open, restart or return to the network.
  int get failures => _failures;

  /// A run is connecting, serving or waiting to retry.
  bool get running => _run != null;

  /// Starts a run, replacing any in flight. Completes once its first
  /// attempt has opened or ended.
  Future<void> start() {
    stop();
    _listenConnectivity();
    final run = SocketRun._(this);
    _run = run;
    unawaited(_loop(run));
    return run._settled.future;
  }

  /// Ends the run: its wait wakes and its attempt sees [SocketRun.ended].
  void stop() {
    final run = _run;
    _run = null;
    run?._end();
  }

  void dispose() {
    stop();
    final listener = _connectivityListener;
    if (listener != null) connectivity?.removeListener(listener);
    _connectivityListener = null;
  }

  Future<void> _loop(SocketRun run) async {
    _failures = 0;
    while (run.live) {
      SocketEnd end;
      try {
        end = await attempt(run);
      } catch (e) {
        logDebug('$name attempt failed: $e');
        end = SocketEnd.dropped;
      }
      run._settle();
      if (!run.live || end == SocketEnd.fatal) break;
      if (end == SocketEnd.reconnectNow) continue;
      _failures++;
      final cap = maxAttempts;
      if (cap != null && _failures > cap) {
        logDebug('$name gave up after $_failures attempts');
        await run._sleep(null);
      } else {
        await run._sleep(backoff(_failures));
      }
    }
    run._settle();
    if (identical(_run, run)) _run = null;
  }

  void _listenConnectivity() {
    final service = connectivity;
    if (service == null || _connectivityListener != null) return;
    _wasOnline = service.isOnline;
    _connectivityListener = () {
      if (service.isOnline && !_wasOnline) {
        _failures = 0;
        _run?._wake();
      }
      _wasOnline = service.isOnline;
    };
    service.addListener(_connectivityListener!);
  }
}

/// One run of a [SocketLoop], as its attempts see it.
class SocketRun {
  SocketRun._(this._loop);

  final SocketLoop _loop;
  bool _live = true;
  final _ended = Completer<void>();
  final _settled = Completer<void>();
  Completer<void>? _sleeper;
  Timer? _sleepTimer;

  /// False once the loop stopped or restarted: the attempt should close
  /// its socket and return.
  bool get live => _live;

  /// Completes when [live] turns false.
  Future<void> get ended => _ended.future;

  /// The protocol handshake finished (IRC login, EventSub welcome, 7TV
  /// hello): the failure count starts over.
  void opened() {
    if (_live) _loop._failures = 0;
  }

  /// Waits for [channel]'s handshake, up to the loop's connect timeout, and
  /// settles [SocketLoop.start] once it opens. Throws when it fails, times
  /// out or the run ends first.
  Future<void> ready(WebSocketChannel channel) {
    final done = Completer<void>();
    void fail(Object e, [StackTrace? st]) {
      if (!done.isCompleted) done.completeError(e, st);
    }

    if (!_live) fail(StateError('${_loop.name} stopped'));
    final timer = Timer(
      _loop.connectTimeout,
      () => fail(TimeoutException('${_loop.name} connect timed out')),
    );
    channel.ready.then((_) {
      if (done.isCompleted) return;
      done.complete();
      _settle();
    }, onError: fail);
    _abortReady = () => fail(StateError('${_loop.name} stopped'));
    return done.future.whenComplete(() {
      timer.cancel();
      _abortReady = null;
    });
  }

  VoidCallback? _abortReady;

  void _settle() {
    if (!_settled.isCompleted) _settled.complete();
  }

  /// Waits [delay], or until woken when null.
  Future<void> _sleep(Duration? delay) {
    final sleeper = Completer<void>();
    _sleeper = sleeper;
    if (delay != null) _sleepTimer = Timer(delay, _wake);
    return sleeper.future;
  }

  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final sleeper = _sleeper;
    _sleeper = null;
    if (sleeper != null && !sleeper.isCompleted) sleeper.complete();
  }

  void _end() {
    _live = false;
    _wake();
    _abortReady?.call();
    if (!_ended.isCompleted) _ended.complete();
  }
}
