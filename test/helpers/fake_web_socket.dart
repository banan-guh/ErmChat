import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketSink implements WebSocketSink {
  FakeWebSocketSink(this.onLine);

  final void Function(String line)? onLine;
  final List<String> sent = [];

  StreamSink<dynamic> get sink => this;

  @override
  void add(dynamic data) {
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
  Future<void> get done => Future<void>.value();
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
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  List<String> get sent => _sink.sent;

  void push(String line) => _controller.add(line);

  void failNow() => _controller.addError(Exception('socket died'));

  void dispose() => _controller.close();
}
