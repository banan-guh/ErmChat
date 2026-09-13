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
      listener(value);
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
      listener();
    }
  }

  void clear() => _listeners.clear();
}

/// Output ports the emote controller pushes at the shell: a user-facing
/// notice and the manual-refresh busy flag.
class EmoteSignals {
  final ChatSignal<String> snack = ChatSignal<String>();
  final ChatSignal<bool> busy = ChatSignal<bool>();

  void dispose() {
    snack.clear();
    busy.clear();
  }
}
