import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/twitch_message.dart';

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

typedef UserEmoteSetsSignal = ({String? channel, List<String> ids});
typedef WhisperSystemSignal = ({String channel, String text});
typedef WhisperSentSignal = ({String target, String message});

/// Provider-owned output port for everything the pipeline pushes at the UI.
/// The shell subscribes and forwards each signal to its existing owner, so
/// the pipeline never holds a reference to a screen.
class ChatUiSignals {
  final ChatVoidSignal focusComposer = ChatVoidSignal();
  final ChatSignal<String> banner = ChatSignal<String>();
  final ChatSignal<TwitchMessage> whisper = ChatSignal<TwitchMessage>();
  final ChatSignal<UserEmoteSetsSignal> userEmoteSets =
      ChatSignal<UserEmoteSetsSignal>();
  final ChatSignal<WhisperSystemSignal> whisperSystem =
      ChatSignal<WhisperSystemSignal>();
  final ChatSignal<WhisperSentSignal> whisperSent =
      ChatSignal<WhisperSentSignal>();

  void dispose() {
    focusComposer.clear();
    banner.clear();
    whisper.clear();
    userEmoteSets.clear();
    whisperSystem.clear();
    whisperSent.clear();
  }
}

final chatUiSignalsProvider = Provider<ChatUiSignals>((ref) {
  final signals = ChatUiSignals();
  ref.onDispose(signals.dispose);
  return signals;
});
