import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../emotes/emote.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../chat/chat.dart';
import '../client/session.dart';
import '../services/command_handler.dart';
import '../services/emote_manager.dart';
import '../services/emote_usage_registry.dart';
import 'suggestion.dart';
import '../services/twitch_auth.dart';
import '../services/user_store.dart';
import '../util/duration_format.dart';
import '../util/haptics.dart';
import '../util/log.dart';
import '../widgets/panel_manager.dart';
import 'autocomplete_revert.dart';
import '../l10n/l10n.dart';

// Input box state and send gating. Owns the text/focus controllers,
// autocomplete, reply target, and cooldown countdown.
class ComposerController {
  ComposerController({
    required this.chatConn,
    required this.commandHandler,
    required this.twitchAuth,
    required this.emoteSource,
    required this.emoteUsage,
    required this.userStore,
    required this.chat,
    required this.session,
    required this.getReplyTo,
    required this.setReplyTo,
    required this.getSelectedChannel,
    required this.isWhispersTabActive,
    required this.whisperTarget,
    required this.activePanel,
    required this.threadsTabIndex,
    required this.openThreadRoot,
    required this.replyToRoot,
    required this.preferEmotesFirst,
    required this.computeThreadMessages,
    required this.channelChatReady,
    required this.showNotice,
    required this.strings,
    required this.emoteSheetOpen,
    required this.closeEmoteSheet,
    required this.showEmoteMenu,
    required this.markDirty,
  }) {
    focusNode.addListener(_onInputFocusChanged);
    messageController.addListener(_onInputChanged);
    _cooldownTickTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => refreshCooldown(),
    );
  }

  final ChatConnectionManager chatConn;
  final CommandHandler commandHandler;
  final TwitchAuth twitchAuth;
  final EmoteLookupSource emoteSource;
  final EmoteUsageRegistry emoteUsage;
  final UserStore userStore;
  final Session session;
  final Chat chat;
  final TwitchMessage? Function() getReplyTo;
  final void Function(TwitchMessage?) setReplyTo;
  final String? Function() getSelectedChannel;
  final bool Function() isWhispersTabActive;
  final String? Function() whisperTarget;
  final OverlayPanel Function() activePanel;
  final int Function() threadsTabIndex;
  final TwitchMessage? Function() openThreadRoot;
  final bool Function() replyToRoot;
  final bool Function() preferEmotesFirst;
  final List<TwitchMessage> Function() computeThreadMessages;
  final bool Function() channelChatReady;
  final void Function(String text) showNotice;
  final AppLocalizations Function() strings;
  final bool Function() emoteSheetOpen;
  final Future<void> Function() closeEmoteSheet;
  final void Function() showEmoteMenu;
  final void Function() markDirty;

  final messageController = TextEditingController();
  final autocompleteRevert = AutocompleteRevertFormatter();
  final focusNode = FocusNode();
  final suggestions = ValueNotifier<List<Suggestion>>([]);
  final cooldownLabel = ValueNotifier<String?>(null);

  String? _lastSentText;
  Timer? _cooldownTickTimer;

  String? get selectedChannel => getSelectedChannel();

  void dispose() {
    _cooldownTickTimer?.cancel();
    focusNode.removeListener(_onInputFocusChanged);
    messageController.removeListener(_onInputChanged);
    messageController.dispose();
    focusNode.dispose();
    suggestions.dispose();
    cooldownLabel.dispose();
  }

  void focus() => focusNode.requestFocus();
  void unfocus() => focusNode.unfocus();
  bool get hasFocus => focusNode.hasFocus;

  // Reply state is owned by replyToProvider; these are plain forwarders.
  TwitchMessage? get replyToMsg => getReplyTo();
  set replyTo(TwitchMessage? v) => setReplyTo(v);

  void startReply(TwitchMessage msg) {
    setReplyTo(msg);
    markDirty();
    focusNode.requestFocus();
  }

  void clearReply() {
    setReplyTo(null);
    markDirty();
  }

  void clearSuggestions() {
    if (suggestions.value.isNotEmpty) suggestions.value = [];
  }

  // Channel switch: drop stale suggestions. The emote list itself is read
  // live from the shared mixer per keystroke, so no cache to invalidate.
  void onChannelChanged() {
    autocompleteRevert.clear();
    clearSuggestions();
  }

  void onTapClearSuggestions() => suggestions.value = [];

  void toggleEmoteMenu() {
    PerfLog.I.record('EmoteSheet', 'toggle: open=${emoteSheetOpen()}');
    if (emoteSheetOpen()) {
      unawaited(closeEmoteSheet());
    } else {
      showEmoteMenu();
    }
  }

  void _onInputFocusChanged() {
    if (emoteSheetOpen()) unawaited(closeEmoteSheet());
  }

  void _onInputChanged() {
    final text = messageController.text;
    final cursor = messageController.selection.baseOffset;
    final word = getCurrentWord(text, cursor, extendRight: false);
    final isCommand = word.text.startsWith('/');
    var filterWord = word.text;
    if (isCommand) {
      filterWord = filterWord.substring(1);
    } else if (filterWord.startsWith('@') && filterWord.length >= 2) {
      filterWord = filterWord.substring(1);
    }
    if (filterWord.length < 2 && !isCommand) {
      clearSuggestions();
      return;
    }
    final channel = getSelectedChannel();
    if (channel == null) {
      return;
    }

    final List<Suggestion> filtered;
    if (isCommand) {
      // All commands are suggested regardless of permissions; the API
      // rejects what the account cannot run (clean error notice shown).
      filtered = filterSuggestions(
        word: word.text,
        emotes: <Emote>[],
        users: const <String>[],
        commands: CommandHandler.allCommands,
      );
    } else {
      final users = userStore.usersForChannel(channel);
      final isMention = word.text.startsWith('@');
      // Same base mixer chat renders from, read live per keystroke. The
      // viewer id keeps personal grants in scope; foreign sets never leak
      // into typing because foreignFor(viewer) is always null by design.
      final emotes = isMention
          ? <Emote>[]
          : emoteSource.lookup(channel, session.userId)?.suggestions ??
                const <Emote>[];
      filtered = filterSuggestions(
        word: filterWord,
        emotes: emotes,
        users: users,
        preferEmotesFirst: preferEmotesFirst(),
        recentEmoteIds: emoteUsage.recentEmoteIds,
      );
    }
    suggestions.value = filtered;
  }

  void selectSuggestion(Suggestion suggestion) {
    var replacement = switch (suggestion) {
      UserSuggestion() => suggestion.displayName,
      EmoteSuggestion() => suggestion.emote.code,
      CommandSuggestion() => suggestion.command,
    };

    final textBefore = messageController.text;
    final cursorBefore = messageController.selection.baseOffset;
    final wordBefore = getCurrentWord(
      textBefore,
      cursorBefore,
      extendRight: false,
    );

    if (suggestion is UserSuggestion) {
      if (wordBefore.text.startsWith('@')) replacement = '@$replacement';
    }

    final inserted = replaceCurrentWord(
      messageController,
      replacement,
      extendRight: false,
    );
    autocompleteRevert.markReplaced(
      start: wordBefore.start,
      original: wordBefore.text,
      replacement: inserted,
    );

    if (suggestion is EmoteSuggestion) {
      emoteUsage.markEmoteUsed(suggestion.emote);
    }
    suggestions.value = [];
    focusNode.requestFocus();
  }

  void send() {
    iosHaptic(HapticFeedback.lightImpact);
    clearSuggestions();

    final text = messageController.text.trim();
    final channel = getSelectedChannel();
    if (text.isEmpty || channel == null) return;

    if (!twitchAuth.isConfigured) {
      showNotice(strings().connectToChat);
      return;
    }

    // Whispers tab composes whispers: slash commands go through the
    // handler, plain text replies to the latest whisper partner.
    if (isWhispersTabActive()) {
      if (text.startsWith('/')) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        chatConn.doSendMessage(text, channel);
      } else if (whisperTarget() != null) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        unawaited(
          commandHandler.handle(
            '/w ${whisperTarget()} $text',
            channel,
            twitchAuth,
          ),
        );
      } else {
        showNotice(strings().whisperUsageNotice);
      }
      return;
    }

    // Mentions tab stays read-only, as do the threads dashboard lists:
    // replies are composed from the Thread tab only. Mod view greys out
    // the global box, except the Terms tab which borrows it for new terms.
    if (activePanel() == OverlayPanel.mentions) return;
    if (activePanel() == OverlayPanel.modView) return;
    if (activePanel() == OverlayPanel.thread && threadsTabIndex() != 0) {
      return;
    }

    // Send gates are soft: the countdown shows as a hint but the message is
    // never held back. Twitch enforces the real block, a successful echo
    // heals a stale self-timeout gate, and a rejection NOTICE re-surfaces it.
    _lastSentText = text;
    autocompleteRevert.clear();
    messageController.clear();

    final threadRoot = openThreadRoot();
    if (threadRoot != null) {
      // The reply lands in the thread's channel, which can differ from the
      // selected channel when a saved thread from another channel is open.
      final targetChannel = threadRoot.channel ?? channel;
      final threadMsgs = computeThreadMessages();
      final TwitchMessage? replyTo;
      if (replyToRoot()) {
        final rootId = threadRoot.replyThreadRootId ?? threadRoot.messageId;
        replyTo = threadMsgs.firstWhere(
          (m) => m.messageId == rootId,
          orElse: () => TwitchMessage(
            login: '',
            text: '',
            messageId: rootId,
            channel: targetChannel,
          ),
        );
      } else {
        // Newest-first thread order: the latest reply sits at index 0.
        replyTo = threadMsgs.isNotEmpty ? threadMsgs.first : null;
      }
      chatConn.doSendMessage(text, targetChannel, replyTo: replyTo);
    } else {
      chatConn.doSendMessage(text, channel);
    }
  }

  // Long-press send recalls the last sent text for quick re-send/edit.
  void recallLastSent() {
    if (_lastSentText != null && _lastSentText!.isNotEmpty) {
      autocompleteRevert.clear();
      messageController.text = _lastSentText!;
      messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: messageController.text.length),
      );
      focusNode.requestFocus();
    }
  }

  // Emote picker tap: insert the code at the cursor plus a space.
  void insertEmoteAtCursor(Emote emote) {
    final text = messageController.text;
    final pos = messageController.selection.baseOffset;
    final insertPos = pos.clamp(0, text.length);
    autocompleteRevert.clear();
    messageController.text =
        '${text.substring(0, insertPos)}${emote.code} ${text.substring(insertPos)}';
    messageController.selection = TextSelection.collapsed(
      offset: insertPos + emote.code.length + 1,
    );
    emoteUsage.markEmoteUsed(emote);
  }

  // Input-box send gate ("Slow mode: 12s" / "Timed out: 5s"). Your own
  // timeout wins over the slow-mode window.
  String? cooldownText() {
    final channel = getSelectedChannel();
    if (channel == null || !chat.contains(channel)) return null;
    final timeout = chatConn.remainingSelfTimeout(channel);
    if (timeout != null) {
      return strings().timedOutCountdown(formatSeconds(timeout));
    }
    final slow = chatConn.remainingSlowCooldown(channel);
    if (slow != null) return strings().slowModeCountdown(formatSeconds(slow));
    return null;
  }

  void refreshCooldown() => cooldownLabel.value = cooldownText();

  bool get enabled =>
      activePanel() != OverlayPanel.modView &&
      (activePanel() != OverlayPanel.mentions || isWhispersTabActive()) &&
      (activePanel() != OverlayPanel.thread || threadsTabIndex() == 0) &&
      twitchAuth.isConfigured &&
      // Token without a session user means the identity is still resolving
      // (account switch, fresh login): the pipeline would drop the send.
      session.login != null &&
      chatConn.isChatPipeConnected &&
      (isWhispersTabActive() || channelChatReady());

  /// [withStatus] lets the channel status fill the generic hint; landscape
  /// uses it in place of the status row under the input.
  String? hintText({bool withStatus = false}) =>
      cooldownLabel.value ??
      (!twitchAuth.isConfigured
          ? strings().connectToChat
          : switch ((
              chatConn.connectPhase,
              activePanel(),
              isWhispersTabActive(),
              channelChatReady(),
            )) {
              (ChatPhase.connecting, _, _, _) => strings().connectingHint,
              (ChatPhase.reconnecting, _, _, _) => strings().reconnectingHint,
              (ChatPhase.online, _, false, false)
                  when getSelectedChannel() != null =>
                strings().disconnectedHint,
              (_, OverlayPanel.thread, _, _) when threadsTabIndex() == 0 =>
                strings().replyToThreadHint,
              (_, OverlayPanel.thread, _, _) => strings().selectThreadHint,
              (_, OverlayPanel.modView, _, _) => strings().modViewOpenHint,
              (_, _, true, _) =>
                whisperTarget() != null
                    ? strings().whisperToHint(whisperTarget()!)
                    : strings().whisperUsageHint,
              (_, OverlayPanel.mentions, _, _) => strings().typeMessageHint,
              // Stream and room status ("Live with … · Slow (30s)") fills an
              // otherwise generic hint, so it costs no height of its own.
              _ => withStatus ? _channelStatus() : null,
            });

  String? _channelStatus() {
    final status = chat.channelFor(getSelectedChannel() ?? '')?.info.status;
    return status == null || status.isEmpty ? null : status;
  }
}
