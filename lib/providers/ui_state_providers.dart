import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/twitch_message.dart';
import '../services/command_macros.dart';
import '../util/constants.dart';
import '../util/prefs.dart';
import '../util/settings.dart';
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
  // With the archive on, history past the buffer reads from disk. Both read
  // the toggle once at launch.
  @override
  int build() {
    final cap = Settings.maxMessagesPerChannel;
    if (Settings.archiveEnabled.value) return kLiveBufferMessages;
    void sync() => state = cap.value;
    cap.addListener(sync);
    ref.onDispose(() => cap.removeListener(sync));
    return cap.value;
  }
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

/// Whether mentions notify while the app is open. Mirrors the pref;
/// [HomeScreen] applies it on load and on every prefs change.
/// When muted notifications come back, or null when they aren't muted.
/// Rules keep their notify setting; a mute only silences them.
class NotificationPauseNotifier extends Notifier<DateTime?> {
  NotificationPauseNotifier({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  @override
  DateTime? build() => null;

  DateTime get now => _now();

  bool get paused {
    final until = state;
    return until != null && _now().isBefore(until);
  }

  void pauseFor(Duration duration) => _set(_now().add(duration));

  void resume() => _set(null);

  /// Startup load from prefs; an expired pause loads as none.
  void restore(int? untilMs) {
    final until = untilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(untilMs, isUtc: true);
    state = until != null && _now().isBefore(until) ? until : null;
  }

  void _set(DateTime? until) {
    state = until;
    unawaited(
      Prefs.load().then(
        (prefs) =>
            prefs.setNotificationsPausedUntil(until?.millisecondsSinceEpoch),
      ),
    );
  }
}

final notificationPauseProvider =
    NotifierProvider<NotificationPauseNotifier, DateTime?>(
      NotificationPauseNotifier.new,
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
