import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketSink implements WebSocketSink {
  FakeWebSocketSink(this.onLine);

  final void Function(String line)? onLine;
  final List<String> sent = [];
  final _done = Completer<void>();
  bool throwOnNextAdd = false;

  StreamSink<dynamic> get sink => this;

  @override
  void add(dynamic data) {
    if (throwOnNextAdd) {
      throwOnNextAdd = false;
      throw StateError('write failed');
    }
    final line = data as String;
    sent.add(line);
    onLine?.call(line);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  Future<void> get done => _done.future;

  void finish() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// A controllable [WebSocketChannel] for connection tests: `failReady`
/// simulates a failed handshake, `push` delivers lines, `failNow` kills the
/// stream with an error.
class FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  FakeWebSocketChannel({
    this.failReady = false,
    this.readyCompleter,
    this.autoPong = false,
  });

  /// Answers every outgoing client `PING :x` with an incoming `PONG :x`
  /// (one microtask later), mimicking Twitch. Off by default so keepalive
  /// timeout tests keep exercising the dead-socket paths.
  final bool autoPong;

  final bool failReady;
  final Completer<void>? readyCompleter;
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  late final FakeWebSocketSink _sink = FakeWebSocketSink(_onOutgoingLine);
  int? _closeCode;

  void _onOutgoingLine(String line) {
    if (!autoPong || !line.startsWith('PING')) return;
    scheduleMicrotask(() => push('PONG${line.substring(4)}'));
  }

  @override
  Future<void> get ready {
    if (readyCompleter != null) return readyCompleter!.future;
    return failReady
        ? Future.error(Exception('connect failed'))
        : Future.value();
  }

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  List<String> get sent => _sink.sent;

  /// The peer stopped reading writes while the inbound stream stays open.
  void closeWriteSide() => _sink.finish();

  /// The peer closed the whole socket with an optional close code.
  void peerClose({int? code}) {
    _closeCode = code;
    _controller.close();
  }

  /// The next outbound write fails synchronously, as a closed sink can.
  void failNextWrite() => _sink.throwOnNextAdd = true;

  void push(String line) => _controller.add(line);

  void failNow() => _controller.addError(Exception('socket died'));

  void dispose() => _controller.close();
}
