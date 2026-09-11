import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_connection_manager.dart';
import 'app_providers.dart';
import 'chat_signals.dart';
import 'feature_providers.dart';
import 'ui_state_providers.dart';

export 'chat_signals.dart';

/// The chat pipeline, wired entirely from providers. The adapter below maps
/// read-state providers and the signal sink onto the manager's
/// [ChatViewBridge] / [ChatSinks] ports; the shell only observes the result.
final chatPipelineProvider = Provider<ChatConnectionManager>((ref) {
  final chat = ref.read(chatProvider);
  final session = ref.read(sessionProvider);
  final signals = ref.read(chatUiSignalsProvider);

  final manager = ChatConnectionManager(
    ChatConnectionConfig(
      services: ChatServices(
        twitchApi: ref.read(twitchApiProvider),
        eventSub: ref.read(eventSubServiceProvider),
        irc: ref.read(ircServiceProvider),
        ircRead: ref.read(ircReadServiceProvider),
        sevenTvClient: ref.read(sevenTvClientProvider),
        emoteManager: ref.read(emoteManagerProvider),
        badgeService: ref.read(badgeServiceProvider),
        userStore: ref.read(userStoreProvider),
        twitchAuth: ref.read(twitchAuthProvider),
        pingManager: ref.read(pingManagerProvider),
        ignoreManager: ref.read(ignoreManagerProvider),
        joinBudget: ref.read(joinBudgetProvider),
      ),
      chat: chat,
      session: session,
      bridge: ChatViewBridge(
        mentionsChannel: '@mentions',
        getSelectedChannel: () => ref.read(selectedChannelProvider),
        getMaxMessagesPerChannel: () => ref.read(maxMessagesPerChannelProvider),
        onSystemMessage: (channel, text, {accent, messageId}) {
          final messages = chat.channelFor(channel)?.messages;
          if (messages == null) return;
          if (!messages.addSystem(text, accent: accent, messageId: messageId)) {
            return;
          }
          chat
              .channelFor(channel)
              ?.truncate(ref.read(maxMessagesPerChannelProvider));
        },
        onJoinProgress: (channel, info) =>
            signals.joinProgress.emit((channel: channel, info: info)),
        onBanner: signals.banner.emit,
        onFocusComposer: signals.focusComposer.emit,
      ),
      sinks: ChatSinks(
        onCommand: (text, channel, auth) =>
            signals.command.emit((text: text, channel: channel, auth: auth)),
        getReplyToMsg: () => ref.read(replyToProvider),
        setReplyToMsg: (value) => ref.read(replyToProvider.notifier).set(value),
        onUserEmoteSets: (channel, ids) async =>
            signals.userEmoteSets.emit((channel: channel, ids: ids)),
        onReconnected: signals.reconnected.emit,
        getMacros: () => ref.read(macrosProvider),
        isChatReady: () => ref.read(chatReadyProvider),
        isBlocked: (login) =>
            ref.read(blockedLoginsProvider).contains(login.toLowerCase()),
        getSharedChatMode: () => ref.read(sharedChatModeProvider),
        onAnalyticsMessage: (channel, msg) =>
            ref.read(analyticsServiceProvider).recordMessage(channel, msg),
        onAnalyticsModeration: (channel, isTimeout) => ref
            .read(analyticsServiceProvider)
            .recordModeration(channel, isTimeout),
        onHypeTrain: signals.hypeTrain.emit,
        onPoll: signals.poll.emit,
        onPrediction: signals.prediction.emit,
        onChatMessage: (channel, msg) => ref
            .read(ttsControllerProvider)
            .handleMessage(channel, msg, ref.read(selectedChannelProvider)),
      ),
    ),
  );
  // These two live as mutable manager fields, not config ports, so the
  // adapter wires them to the signal sink directly.
  manager.onMention = (channel, msg) =>
      signals.mention.emit((channel: channel, message: msg));
  manager.onWhisper = signals.whisper.emit;
  ref.onDispose(manager.dispose);
  return manager;
});

/// Mirrors the pipeline connection-state port as Riverpod state so the shell
/// observes it with [ref.listen] instead of a manual listener.
class ConnectionStateBridge extends Notifier<int> {
  @override
  int build() {
    final notifier = ref.watch(chatPipelineProvider).connectionStateNotifier;
    void onChange() => state = notifier.value;
    notifier.addListener(onChange);
    ref.onDispose(() => notifier.removeListener(onChange));
    return notifier.value;
  }
}

final connectionStateProvider = NotifierProvider<ConnectionStateBridge, int>(
  ConnectionStateBridge.new,
);
