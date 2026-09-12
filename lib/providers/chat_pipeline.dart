import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_connection_manager.dart';
import 'app_providers.dart';
import 'chat_signals.dart';
import 'feature_providers.dart';
import 'ui_state_providers.dart';

export 'chat_signals.dart';

/// The chat pipeline, wired entirely from providers. The adapter below maps
/// read-state providers and the signal sink onto the manager's
/// [ChatViewBridge] / [ChatSinks] ports; the shell drives connect/reconnect
/// and observes the result.
final chatPipelineProvider = Provider<ChatConnectionManager>((ref) {
  final chat = ref.read(chatProvider);
  final session = ref.read(sessionProvider);
  final signals = ref.read(chatUiSignalsProvider);

  // Kernel system-line write plus truncate, shared by every system sink.
  void writeSystem(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  }) {
    chat
        .channelFor(channel)
        ?.addSystemMessage(
          text,
          accent: accent,
          messageId: messageId,
          maxMessages: ref.read(maxMessagesPerChannelProvider),
        );
  }

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
        onSystemMessage: (channel, text, {accent, messageId}) =>
            writeSystem(channel, text, accent: accent, messageId: messageId),
        onJoinProgress: (channel, info) {
          final text = info == null
              ? null
              : info.position <= 0
              ? 'Joining #$channel...'
              : info.etaSeconds <= 0
              ? 'Joining: position ${info.position}'
              : 'Joining: position ${info.position}, ~${info.etaSeconds}s';
          chat
              .channelFor(channel)
              ?.setJoinWait(
                text,
                maxMessages: ref.read(maxMessagesPerChannelProvider),
              );
        },
        onBanner: signals.banner.emit,
        onFocusComposer: signals.focusComposer.emit,
      ),
      sinks: ChatSinks(
        onCommand: (text, channel, auth) async {
          try {
            await ref.read(commandHandlerProvider).handle(text, channel, auth);
          } catch (e) {
            writeSystem(channel, 'Command failed: $e');
          }
        },
        getReplyToMsg: () => ref.read(replyToProvider),
        setReplyToMsg: (value) => ref.read(replyToProvider.notifier).set(value),
        onUserEmoteSets: (channel, ids) async =>
            signals.userEmoteSets.emit((channel: channel, ids: ids)),
        onReconnected: () {
          ref.read(chatHistoryControllerProvider).refetchAll();
          ref.read(reconnectedTickProvider.notifier).bump();
        },
        onMention: (channel, msg) =>
            ref.read(mentionNotifierProvider).handle(channel, msg),
        onWhisper: signals.whisper.emit,
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
        onHypeTrain: (event) =>
            ref.read(broadcastWidgetsProvider).onHypeTrain(event),
        onPoll: (event) => ref.read(broadcastWidgetsProvider).onPoll(event),
        onPrediction: (event) =>
            ref.read(broadcastWidgetsProvider).onPrediction(event),
        onChatMessage: (channel, msg) => ref
            .read(ttsControllerProvider)
            .handleMessage(channel, msg, ref.read(selectedChannelProvider)),
      ),
    ),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Mirrors the pipeline connection-state port as Riverpod state so the shell
/// observes it with [ref.listen] instead of a manual listener.
final connectionStateProvider = NotifierProvider<ChangeNotifierTick, int>(
  () => ChangeNotifierTick(
    (ref) => ref.watch(chatPipelineProvider).connectionStateNotifier,
  ),
);
