import '../models/twitch_message.dart';
import '../util/signal.dart';

/// What chat hides without deleting. Hidden rows stay in the buffer and the
/// archive, count for nothing (unread, mentions), and draw as nothing, so a
/// rule change shows them again. System rows always show.
class ChatFilter {
  bool Function(TwitchMessage msg) _rule = _none;
  int _version = 0;

  static bool _none(TwitchMessage _) => false;

  /// Each row's answer and the rule version it was taken under.
  final _answers = Expando<(int, bool)>();

  /// Fires after the rule or what it reads changes.
  final changed = ChatVoidSignal();

  set rule(bool Function(TwitchMessage msg) rule) {
    _rule = rule;
    invalidate();
  }

  bool hides(TwitchMessage msg) {
    if (msg.isSystem) return false;
    final answer = _answers[msg];
    if (answer != null && answer.$1 == _version) return answer.$2;
    final hidden = _rule(msg);
    _answers[msg] = (_version, hidden);
    return hidden;
  }

  /// Drops remembered answers after something the rule reads changes.
  void invalidate() {
    _version++;
    changed.emit();
  }
}
