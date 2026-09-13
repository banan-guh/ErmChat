import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/twitch_message.dart';
import '../util/signal.dart';

export '../util/signal.dart' show ChatSignal, ChatVoidSignal;

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
