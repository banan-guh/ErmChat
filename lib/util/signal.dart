import 'package:flutter/foundation.dart';

/// A typed, purpose-named output port. [add] returns an unsubscribe callback
/// so subscribers never rely on tear-off identity to detach.
class ChatSignal<T> {
  final _listeners = <void Function(T)>[];

  void Function() add(void Function(T) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit(T value) {
    for (final listener in List.of(_listeners)) {
      _guard(() => listener(value));
    }
  }

  void clear() => _listeners.clear();
}

/// The no-payload sibling of [ChatSignal].
class ChatVoidSignal {
  final _listeners = <VoidCallback>[];

  void Function() add(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit() {
    for (final listener in List.of(_listeners)) {
      _guard(listener);
    }
  }

  void clear() => _listeners.clear();
}

void _guard(void Function() call) {
  try {
    call();
  } catch (e, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: stack,
        library: 'ermchat',
        context: ErrorDescription('while dispatching a chat signal'),
      ),
    );
  }
}
