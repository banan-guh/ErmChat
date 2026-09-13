import '../util/signal.dart';

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
