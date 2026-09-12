import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../eventsub/transport/connection.dart';
import '../irc/join_rate_limiter.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../services/emote_manager.dart';
import '../services/ignore_manager.dart';
import '../services/ping_manager.dart';
import '../services/pip_service.dart';
import '../services/recent_messages.dart';
import '../services/seven_tv_event_client.dart';
import '../services/seven_tv_paint_service.dart';
import '../services/third_party_badge_service.dart';
import '../services/twitch_api.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../util/connectivity.dart';

/// App-scope shared objects: transports, managers, and the mutable kernel.
///
/// Providers own construction and teardown; consumers read them instead of
/// constructing. The kernel ([Chat]) and [Session] are provider-owned but
/// observed through their leaf `Listenable`s, the one sanctioned non-Riverpod
/// observation path.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(service.dispose);
  return service;
});

final twitchApiProvider = Provider<TwitchApi>((ref) {
  final api = TwitchApi();
  ref.onDispose(api.close);
  return api;
});

final eventSubServiceProvider = Provider<EventSubService>((ref) {
  final service = EventSubService(
    connectivityService: ref.watch(connectivityServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Shared by both IRC sockets: their combined JOIN rate stays inside Twitch's
/// ~20-commands-per-10s limit instead of each socket bursting independently.
final joinBudgetProvider = Provider<JoinRateLimiter>((ref) {
  final limiter = JoinRateLimiter();
  ref.onDispose(limiter.clear);
  return limiter;
});

final ircServiceProvider = Provider<IrcService>((ref) {
  final service = IrcService(
    connectivityService: ref.watch(connectivityServiceProvider),
    joinBudget: ref.watch(joinBudgetProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final ircReadServiceProvider = Provider<IrcReadService>((ref) {
  final service = IrcReadService(
    connectivityService: ref.watch(connectivityServiceProvider),
    joinBudget: ref.watch(joinBudgetProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final sevenTvClientProvider = Provider<SevenTvEventClient>((ref) {
  final client = SevenTvEventClient(
    connectivityService: ref.watch(connectivityServiceProvider),
  );
  ref.onDispose(client.dispose);
  return client;
});

final emoteManagerProvider = Provider<EmoteManager>((ref) {
  final manager = EmoteManager(
    probe: ref.watch(connectivityServiceProvider).checkConnectivity,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final badgeServiceProvider = Provider<TwitchBadgeService>((ref) {
  final service = TwitchBadgeService();
  ref.onDispose(service.close);
  return service;
});

final thirdPartyBadgeServiceProvider = Provider<ThirdPartyBadgeService>((ref) {
  final service = ThirdPartyBadgeService();
  ref.onDispose(service.dispose);
  return service;
});

final sevenTvPaintServiceProvider = Provider<SevenTvPaintService>((ref) {
  final service = SevenTvPaintService();
  ref.onDispose(service.dispose);
  return service;
});

final userStoreProvider = Provider<UserStore>((ref) => UserStore());

final recentMessagesServiceProvider = Provider<RecentMessagesService>(
  (ref) => RecentMessagesService(),
);

final pipServiceProvider = Provider<PipService>((ref) {
  final service = PipService();
  ref.onDispose(service.dispose);
  return service;
});

final pingManagerProvider = Provider<PingManager>(
  (ref) => PingManager.instance,
);

final ignoreManagerProvider = Provider<IgnoreManager>(
  (ref) => IgnoreManager.instance,
);

final chatProvider = Provider<Chat>((ref) {
  final chat = Chat();
  ref.onDispose(chat.dispose);
  return chat;
});

final sessionProvider = Provider<Session>((ref) {
  final session = Session();
  ref.onDispose(session.dispose);
  return session;
});
