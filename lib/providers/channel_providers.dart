import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../channels/channel_session.dart';
import 'app_providers.dart';
import 'chat_pipeline.dart';
import 'feature_providers.dart';
import 'ui_state_providers.dart';

/// Channel membership, history backfill, and selection, owned by the
/// composition root. Constructs the UI-free [ChannelSession] from the shared
/// owners so the session layer is reachable without a widget. The shell wraps
/// it with the UI-only `ChannelManager`.
final channelSessionProvider = Provider<ChannelSession>((ref) {
  final session = ChannelSession(
    chat: ref.watch(chatProvider),
    session: ref.watch(sessionProvider),
    chatConn: ref.watch(chatPipelineProvider),
    irc: ref.watch(ircServiceProvider),
    ircRead: ref.watch(ircReadServiceProvider),
    emoteManager: ref.watch(emoteManagerProvider),
    badgeService: ref.watch(badgeServiceProvider),
    analytics: ref.watch(analyticsServiceProvider),
    streamPlayer: ref.watch(streamPlayerProvider),
    userStore: ref.watch(userStoreProvider),
    history: ref.watch(chatHistoryControllerProvider),
    recentMessagesService: ref.watch(recentMessagesServiceProvider),
    // Read-state stays imperative: the session reads it at call time and must
    // not rebuild when selection or caps change.
    selectedChannel: () => ref.read(selectedChannelProvider),
    setSelectedChannel: (value) =>
        ref.read(selectedChannelProvider.notifier).set(value),
    maxMessages: () => ref.read(maxMessagesPerChannelProvider),
    recentMessagesLimit: () => ref.read(recentMessagesLimitProvider),
  );
  ref.onDispose(session.dispose);
  return session;
});
