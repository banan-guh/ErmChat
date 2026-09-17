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

// Minimal shell state shared by feature hosts. One shell implementation
// satisfies every host interface, so the getters are declared once here.
abstract class ShellState {
  String? get selectedChannel;
  String? get sessionLogin;
  bool get showTimestamps;
  String get timestampFormat;
}

// Shell-owned UI state the composer reads but does not own.
abstract class ComposerHost extends ShellState {
  bool get isWhispersTabActive;
  String? get whisperTarget;
  OverlayPanel get activePanel;
  int get threadsTabIndex;
  TwitchMessage? get openThreadRoot;
  bool get replyToRoot;
  bool get preferEmotesFirst;
  List<TwitchMessage> computeThreadMessages();
  bool get channelChatReady;
  void showNotice(String text);
  bool get emoteSheetOpen;
  Future<void> closeEmoteSheet();
  void showEmoteMenu();
  void markDirty();
}

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
    required this.host,
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
  final ComposerHost host;

  final messageController = TextEditingController();
  final autocompleteRevert = AutocompleteRevertFormatter();
  final focusNode = FocusNode();
  final suggestions = ValueNotifier<List<Suggestion>>([]);
  final cooldownLabel = ValueNotifier<String?>(null);

  String? _lastSentText;
  Timer? _cooldownTickTimer;

  String? get selectedChannel => host.selectedChannel;

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
    host.markDirty();
    focusNode.requestFocus();
  }

  void clearReply() {
    setReplyTo(null);
    host.markDirty();
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
    PerfLog.I.record('EmoteSheet', 'toggle: open=${host.emoteSheetOpen}');
    if (host.emoteSheetOpen) {
      unawaited(host.closeEmoteSheet());
    } else {
      host.showEmoteMenu();
    }
  }

  void _onInputFocusChanged() {
    if (host.emoteSheetOpen) unawaited(host.closeEmoteSheet());
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
    final channel = host.selectedChannel;
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
        preferEmotesFirst: host.preferEmotesFirst,
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
    final channel = host.selectedChannel;
    if (text.isEmpty || channel == null) return;

    if (!twitchAuth.isConfigured) {
      host.showNotice('Connect an account to chat');
      return;
    }

    // Whispers tab composes whispers: slash commands go through the
    // handler, plain text replies to the latest whisper partner.
    if (host.isWhispersTabActive) {
      if (text.startsWith('/')) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        chatConn.doSendMessage(text, channel);
      } else if (host.whisperTarget != null) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        unawaited(
          commandHandler.handle(
            '/w ${host.whisperTarget} $text',
            channel,
            twitchAuth,
          ),
        );
      } else {
        host.showNotice('Type /w <username> <message> to whisper');
      }
      return;
    }

    // Mentions tab stays read-only, as do the threads dashboard lists:
    // replies are composed from the Thread tab only. Mod view greys out
    // the global box, except the Terms tab which borrows it for new terms.
    if (host.activePanel == OverlayPanel.mentions) return;
    if (host.activePanel == OverlayPanel.modView) return;
    if (host.activePanel == OverlayPanel.thread && host.threadsTabIndex != 0) {
      return;
    }

    // Send gates are soft: the countdown shows as a hint but the message is
    // never held back. Twitch enforces the real block, a successful echo
    // heals a stale self-timeout gate, and a rejection NOTICE re-surfaces it.
    _lastSentText = text;
    autocompleteRevert.clear();
    messageController.clear();

    final threadRoot = host.openThreadRoot;
    if (threadRoot != null) {
      // The reply lands in the thread's channel, which can differ from the
      // selected channel when a saved thread from another channel is open.
      final targetChannel = threadRoot.channel ?? channel;
      final threadMsgs = host.computeThreadMessages();
      final TwitchMessage? replyTo;
      if (host.replyToRoot) {
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
    final channel = host.selectedChannel;
    if (channel == null || !chat.contains(channel)) return null;
    final timeout = chatConn.remainingSelfTimeout(channel);
    if (timeout != null) return 'Timed out: ${formatSeconds(timeout)}';
    final slow = chatConn.remainingSlowCooldown(channel);
    if (slow != null) return 'Slow mode: ${formatSeconds(slow)}';
    return null;
  }

  void refreshCooldown() => cooldownLabel.value = cooldownText();

  bool get enabled =>
      host.activePanel != OverlayPanel.modView &&
      (host.activePanel != OverlayPanel.mentions || host.isWhispersTabActive) &&
      (host.activePanel != OverlayPanel.thread || host.threadsTabIndex == 0) &&
      twitchAuth.isConfigured &&
      // Token without a session user means the identity is still resolving
      // (account switch, fresh login): the pipeline would drop the send.
      session.login != null &&
      chatConn.isChatPipeConnected &&
      (host.isWhispersTabActive || host.channelChatReady);

  String? get hintText =>
      cooldownLabel.value ??
      (!twitchAuth.isConfigured
          ? 'Connect an account to chat'
          : switch ((
              chatConn.connectPhase,
              host.activePanel,
              host.isWhispersTabActive,
              host.channelChatReady,
            )) {
              (ChatPhase.connecting, _, _, _) => 'Connecting...',
              (ChatPhase.reconnecting, _, _, _) => 'Reconnecting...',
              (ChatPhase.online, _, false, false)
                  when host.selectedChannel != null =>
                'Disconnected',
              (_, OverlayPanel.thread, _, _) when host.threadsTabIndex == 0 =>
                'Reply to thread...',
              (_, OverlayPanel.thread, _, _) => 'Select a thread to reply...',
              (_, OverlayPanel.modView, _, _) => 'Mod view open',
              (_, _, true, _) =>
                host.whisperTarget != null
                    ? 'Whisper to ${host.whisperTarget}...'
                    : 'Type /w <username> <message>',
              (_, OverlayPanel.mentions, _, _) => 'Type a message...',
              _ => null,
            });
}
