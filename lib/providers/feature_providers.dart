import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/twitch_message.dart';
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

/// Slash-command handler. It owns no resources; whisper routing emits
/// [ChatUiSignals] so it never holds a screen reference.
final commandHandlerProvider = Provider<CommandHandler>((ref) {
  final chat = ref.read(chatProvider);
  final session = ref.read(sessionProvider);
  final signals = ref.read(chatUiSignalsProvider);

  // Blocked rows bypass truncation, so the verb decays them too.
  void sweepBlockedMessages() {
    final blocked = ref.read(blockedLoginsProvider);
    for (final name in List.of(chat.names)) {
      final channel = chat.channelFor(name);
      if (channel == null) continue;
      channel.removeMessages(
        (m) => !m.isSystem && blocked.contains(m.login.toLowerCase()),
      );
    }
  }

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
    onUserBlocked: (login) {
      ref.read(blockedLoginsProvider.notifier).add(login.toLowerCase());
      sweepBlockedMessages();
    },
    onUserUnblocked: (login) =>
        ref.read(blockedLoginsProvider.notifier).remove(login.toLowerCase()),
  );
});

/// Routes a mention ping to the notification service when mention push is on
/// and the app is backgrounded. Owns the ping dedup set (shared-chat mirrors a
/// message under a different room-local id but the same source id).
class MentionNotifier {
  MentionNotifier(this._ref);

  final Ref _ref;
  final _recentMentionPings = <String>{};

  void handle(String channel, TwitchMessage msg) {
    if (!_ref.read(mentionPushProvider)) return;
    if (!_ref.read(backgroundedProvider)) return;
    if (msg.isHistory) return;
    // Per-rule opt-in: only rules with "notify" enabled may buzz.
    if (!(msg.highlight?.notify ?? false)) return;
    final pingKey = msg.sourceMessageId ?? msg.messageId;
    if (pingKey != null) {
      if (!_recentMentionPings.add(pingKey)) return;
      while (_recentMentionPings.length > 64) {
        _recentMentionPings.remove(_recentMentionPings.first);
      }
    }
    _ref
        .read(notificationServiceProvider)
        .showMentionNotification(
          channel: channel,
          userName: msg.displayName,
          message: msg.text,
        );
  }

  void dispose() => _recentMentionPings.clear();
}

final mentionNotifierProvider = Provider<MentionNotifier>((ref) {
  final notifier = MentionNotifier(ref);
  ref.onDispose(notifier.dispose);
  return notifier;
});

/// Bridges any provider-owned [ChangeNotifier] to Riverpod so widgets observe
/// it with `ref.listen` instead of a manual listener. A [ValueNotifier] is a
/// [ChangeNotifier], so this also serves the pipeline connection-state port.
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
