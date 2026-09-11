import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../eventsub/decode/events.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../services/twitch_auth.dart';
import 'app_providers.dart';
import 'feature_providers.dart';
import 'ui_state_providers.dart';

/// A typed, purpose-named output port. [add] returns an unsubscribe callback
/// so subscribers never rely on tear-off identity to detach.
class ChatSignal<T> {
  final _listeners = <void Function(T)>[];

  void Function() add(void Function(T) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit(T value) {
    for (final listener in List.of(_listeners)) {
      listener(value);
    }
  }

  void clear() => _listeners.clear();
}

/// The no-payload sibling of [ChatSignal].
class ChatVoidSignal {
  final _listeners = <VoidCallback>[];

  void Function() add(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void clear() => _listeners.clear();
}

typedef CommandSignal = ({String text, String channel, TwitchAuth auth});
typedef JoinProgressSignal = ({String channel, JoinProgress? info});
typedef MentionSignal = ({String channel, TwitchMessage message});
typedef UserEmoteSetsSignal = ({String? channel, List<String> ids});

/// Provider-owned output port for everything the pipeline pushes at the UI.
/// The shell subscribes and forwards each signal to its existing owner, so
/// the pipeline never holds a reference to a screen.
class ChatUiSignals {
  final ChatVoidSignal focusComposer = ChatVoidSignal();
  final ChatSignal<String> banner = ChatSignal<String>();
  final ChatSignal<CommandSignal> command = ChatSignal<CommandSignal>();
  final ChatVoidSignal reconnected = ChatVoidSignal();
  final ChatSignal<JoinProgressSignal> joinProgress =
      ChatSignal<JoinProgressSignal>();
  final ChatSignal<MentionSignal> mention = ChatSignal<MentionSignal>();
  final ChatSignal<TwitchMessage> whisper = ChatSignal<TwitchMessage>();
  final ChatSignal<UserEmoteSetsSignal> userEmoteSets =
      ChatSignal<UserEmoteSetsSignal>();
  final ChatSignal<HypeTrainEvent> hypeTrain = ChatSignal<HypeTrainEvent>();
  final ChatSignal<PollEvent> poll = ChatSignal<PollEvent>();
  final ChatSignal<PredictionEvent> prediction = ChatSignal<PredictionEvent>();

  void dispose() {
    focusComposer.clear();
    banner.clear();
    command.clear();
    reconnected.clear();
    joinProgress.clear();
    mention.clear();
    whisper.clear();
    userEmoteSets.clear();
    hypeTrain.clear();
    poll.clear();
    prediction.clear();
  }
}

final chatUiSignalsProvider = Provider<ChatUiSignals>((ref) {
  final signals = ChatUiSignals();
  ref.onDispose(signals.dispose);
  return signals;
});

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
