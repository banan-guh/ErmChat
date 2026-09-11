import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/twitch_message.dart';
import '../services/command_macros.dart';
import '../util/constants.dart';
import '../util/prefs.dart';
import 'app_providers.dart';

/// Pipeline-visible shell state. The chat pipeline reads these synchronously
/// while the shell owns the writes and keeps its own rebuild triggers, so
/// none of these providers are watched for rendering.

class SelectedChannelNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) => state = value;
}

final selectedChannelProvider =
    NotifierProvider<SelectedChannelNotifier, String?>(
      SelectedChannelNotifier.new,
    );

class MaxMessagesNotifier extends Notifier<int> {
  @override
  int build() => kMaxMessagesPerChannelDefault;

  void set(int value) => state = value;
}

final maxMessagesPerChannelProvider =
    NotifierProvider<MaxMessagesNotifier, int>(MaxMessagesNotifier.new);

class ReplyToNotifier extends Notifier<TwitchMessage?> {
  @override
  TwitchMessage? build() => null;

  void set(TwitchMessage? value) => state = value;
}

final replyToProvider = NotifierProvider<ReplyToNotifier, TwitchMessage?>(
  ReplyToNotifier.new,
);

class BlockedLoginsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void addAll(Iterable<String> logins) => state = {...state, ...logins};

  void add(String login) => state = {...state, login};

  void remove(String login) => state = {...state}..remove(login);

  void clear() => state = <String>{};
}

final blockedLoginsProvider =
    NotifierProvider<BlockedLoginsNotifier, Set<String>>(
      BlockedLoginsNotifier.new,
    );

class SharedChatModeNotifier extends Notifier<String> {
  @override
  String build() => 'spotlight';

  void set(String value) => state = value;
}

final sharedChatModeProvider = NotifierProvider<SharedChatModeNotifier, String>(
  SharedChatModeNotifier.new,
);

class ChatReadyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final chatReadyProvider = NotifierProvider<ChatReadyNotifier, bool>(
  ChatReadyNotifier.new,
);

/// The active account's macro trigger lookup. The store is warmed by
/// [loadMacros]; callers invalidate this provider after a warm or after the
/// macros screen saves so the next send reads the fresh map.
final macrosProvider = Provider<Map<String, String>>((ref) {
  final login = ref.read(sessionProvider).login;
  if (login == null) return const {};
  return cachedMacroLookup(login) ?? const {};
});

/// Whether mention push notifications are enabled. Persists under the same
/// key the settings screen writes so the value survives restarts.
class MentionPushNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state == value) return;
    state = value;
    unawaited(Prefs.load().then((prefs) => prefs.setMentionPush(value)));
  }
}

final mentionPushProvider = NotifierProvider<MentionPushNotifier, bool>(
  MentionPushNotifier.new,
);

/// Whether the app is currently backgrounded. The mention notifier reads it
/// to avoid buzzing while the user is already looking at chat.
class BackgroundedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final backgroundedProvider = NotifierProvider<BackgroundedNotifier, bool>(
  BackgroundedNotifier.new,
);
