import 'package:flutter/foundation.dart';

import '../models/twitch_message.dart';
import 'channel/messages.dart';

/// The @mentions pseudo buffer. Cross-channel mirroring stays in the caller;
/// this owns buffer laws only.
class Mentions {
  Mentions({required String channel, DateTime Function()? now})
    : messages = Messages(channel: channel, now: now);

  final Messages messages;

  ValueNotifier<int> get version => messages.version;

  int get length => messages.length;
  bool get isEmpty => messages.isEmpty;

  List<TwitchMessage> get items => messages.items;

  void add(List<TwitchMessage> msgs, {required int maxMessages}) {
    messages.mergeMentions(msgs, maxMessages: maxMessages);
  }

  void clear() {
    if (messages.isEmpty) return;
    messages.removeWhere((_) => true);
  }

  void clearForAccountSwitch() => clear();

  void dispose() {
    messages.dispose();
  }
}
