import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../eventsub/decode/events.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../services/twitch_auth.dart';

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

typedef CommandSignal = ({String text, String channel, TwitchAuth auth});
typedef JoinProgressSignal = ({String channel, JoinProgress? info});
typedef MentionSignal = ({String channel, TwitchMessage message});
typedef UserEmoteSetsSignal = ({String? channel, List<String> ids});
typedef WhisperSystemSignal = ({String channel, String text});
typedef WhisperSentSignal = ({String target, String message});
typedef BlockedUserSignal = ({String login, bool blocked});

/// Provider-owned output port for everything the pipeline pushes at the UI.
/// The shell subscribes and forwards each signal to its existing owner, so
/// the pipeline never holds a reference to a screen.
class ChatUiSignals {
  final ChatVoidSignal focusComposer = ChatVoidSignal();
  final ChatSignal<String> banner = ChatSignal<String>();
  final ChatSignal<CommandSignal> command = ChatSignal<CommandSignal>();
  final ChatVoidSignal reconnected = ChatVoidSignal();
  final ChatSignal<JoinProgressSignal> joinProgress =
      ChatSignal<JoinProgressSignal>();
  final ChatSignal<MentionSignal> mention = ChatSignal<MentionSignal>();
  final ChatSignal<TwitchMessage> whisper = ChatSignal<TwitchMessage>();
  final ChatSignal<UserEmoteSetsSignal> userEmoteSets =
      ChatSignal<UserEmoteSetsSignal>();
  final ChatSignal<WhisperSystemSignal> whisperSystem =
      ChatSignal<WhisperSystemSignal>();
  final ChatSignal<WhisperSentSignal> whisperSent =
      ChatSignal<WhisperSentSignal>();
  final ChatSignal<BlockedUserSignal> blockedUser =
      ChatSignal<BlockedUserSignal>();
  final ChatSignal<HypeTrainEvent> hypeTrain = ChatSignal<HypeTrainEvent>();
  final ChatSignal<PollEvent> poll = ChatSignal<PollEvent>();
  final ChatSignal<PredictionEvent> prediction = ChatSignal<PredictionEvent>();

  void dispose() {
    focusComposer.clear();
    banner.clear();
    command.clear();
    reconnected.clear();
    joinProgress.clear();
    mention.clear();
    whisper.clear();
    userEmoteSets.clear();
    whisperSystem.clear();
    whisperSent.clear();
    blockedUser.clear();
    hypeTrain.clear();
    poll.clear();
    prediction.clear();
  }
}

final chatUiSignalsProvider = Provider<ChatUiSignals>((ref) {
  final signals = ChatUiSignals();
  ref.onDispose(signals.dispose);
  return signals;
});
