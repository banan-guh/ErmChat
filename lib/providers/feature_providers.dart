import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics_service.dart';
import '../services/command_handler.dart';
import '../services/mod_actions.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../services/twitch_auth.dart';
import '../widgets/broadcast_widgets.dart';
import '../widgets/chat_notice_bar.dart';
import 'app_providers.dart';
import 'chat_signals.dart';
import 'ui_state_providers.dart';

/// App-scope feature owners that screens consume instead of constructing.
/// Providers own construction and teardown; each resource owner registers
/// [Ref.onDispose]. Reads are imperative, so consumers use `ref.read`.
final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  final emoteManager = ref.read(emoteManagerProvider);
  final service = AnalyticsService(
    emoteLookup: (channel, senderTwitchId) =>
        emoteManager.byCodeForSender(channel, senderTwitchId),
  );
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService();
  ref.onDispose(service.dispose);
  return service;
});

final ttsControllerProvider = Provider<TtsController>((ref) {
  final controller = TtsController();
  ref.onDispose(controller.shutdown);
  return controller;
});

final modActionsProvider = Provider<ModActions>((ref) {
  final chat = ref.read(chatProvider);
  final session = ref.read(sessionProvider);
  return ModActions(
    twitchApi: ref.read(twitchApiProvider),
    getChannelUserIds: () {
      final out = <String, String>{};
      for (final name in chat.names) {
        final id = chat.channelFor(name)?.info.broadcasterId;
        if (id != null) out[name] = id;
      }
      return out;
    },
    getCurrentUserId: () => session.userId,
  );
});

final chatNoticeProvider = Provider<ChatNoticeController>((ref) {
  final controller = ChatNoticeController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// Overridden in `main.dart` with the loaded `TwitchAuth` instance so the
/// secure-storage registry is not rebuilt per read.
final twitchAuthProvider = Provider<TwitchAuth>((ref) {
  final auth = TwitchAuth();
  ref.onDispose(auth.dispose);
  return auth;
});

/// Broadcast chat widgets (hype train, poll, prediction) plus test fakes.
final broadcastWidgetsProvider = Provider<BroadcastWidgets>((ref) {
  final widgets = BroadcastWidgets(
    selectedChannel: () => ref.read(selectedChannelProvider),
  );
  ref.onDispose(widgets.dispose);
  return widgets;
});

/// Slash-command handler. It owns no resources; its chat feedback and whisper
/// routing emit [ChatUiSignals] so it never holds a screen reference.
final commandHandlerProvider = Provider<CommandHandler>((ref) {
  final chat = ref.read(chatProvider);
  final session = ref.read(sessionProvider);
  final signals = ref.read(chatUiSignalsProvider);
  return CommandHandler(
    twitchApi: ref.read(twitchApiProvider),
    irc: ref.read(ircServiceProvider),
    modActions: ref.read(modActionsProvider),
    getChannelUserIds: () {
      final out = <String, String>{};
      for (final name in chat.names) {
        final id = chat.channelFor(name)?.info.broadcasterId;
        if (id != null) out[name] = id;
      }
      return out;
    },
    getCurrentUserId: () => session.userId,
    getCurrentUserLogin: () => session.login,
    addSystemMessage: (channel, text) {
      final messages = chat.channelFor(channel)?.messages;
      if (messages == null) return;
      if (!messages.addSystem(text)) return;
      chat
          .channelFor(channel)
          ?.truncate(ref.read(maxMessagesPerChannelProvider));
    },
    whisperAddSystemMessage: (channel, text) =>
        signals.whisperSystem.emit((channel: channel, text: text)),
    onWhisperSent: (target, message) =>
        signals.whisperSent.emit((target: target, message: message)),
    onUserBlocked: (login) =>
        signals.blockedUser.emit((login: login, blocked: true)),
    onUserUnblocked: (login) =>
        signals.blockedUser.emit((login: login, blocked: false)),
  );
});

/// Bridges a provider-owned [ChangeNotifier] to Riverpod so widgets observe it
/// with `ref.listen` instead of a manual listener.
class ChangeNotifierTick extends Notifier<int> {
  ChangeNotifierTick(this._select);

  final ChangeNotifier Function(Ref ref) _select;

  @override
  int build() {
    final notifier = _select(ref);
    void onChange() => state = state + 1;
    notifier.addListener(onChange);
    ref.onDispose(() => notifier.removeListener(onChange));
    return 0;
  }
}

final emoteManagerTickProvider = NotifierProvider<ChangeNotifierTick, int>(
  () => ChangeNotifierTick((ref) => ref.watch(emoteManagerProvider)),
);

final twitchAuthTickProvider = NotifierProvider<ChangeNotifierTick, int>(
  () => ChangeNotifierTick((ref) => ref.watch(twitchAuthProvider)),
);

final connectivityTickProvider = NotifierProvider<ChangeNotifierTick, int>(
  () => ChangeNotifierTick((ref) => ref.watch(connectivityServiceProvider)),
);
