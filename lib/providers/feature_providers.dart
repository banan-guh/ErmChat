import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics_service.dart';
import '../services/mod_actions.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../services/twitch_auth.dart';
import '../widgets/chat_notice_bar.dart';
import 'app_providers.dart';

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
