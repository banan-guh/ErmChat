import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/command_handler.dart';
import '../services/emote_manager.dart';
import '../services/suggestion.dart';
import '../services/twitch_auth.dart';
import '../services/user_store.dart';
import '../util/duration_format.dart';
import '../util/haptics.dart';
import '../util/log.dart';
import '../widgets/panel_manager.dart';

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
    required this.emoteManager,
    required this.userStore,
    required this.chatStore,
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
  final EmoteManager emoteManager;
  final UserStore userStore;
  final ChatStore chatStore;
  final ComposerHost host;

  final messageController = TextEditingController();
  final focusNode = FocusNode();
  final suggestions = ValueNotifier<List<Suggestion>>([]);
  final cooldownLabel = ValueNotifier<String?>(null);

  TwitchMessage? replyToMsg;
  String? _lastSentText;
  List<GenericEmote>? _cachedAutocompleteEmotes;
  ({int start, String originalText, String replacementText})? _lastAutoUndo;
  String? _previousTextForUndo;
  String? _undoExpectedAfter;
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

  // Plain setter for pipeline-tracked replies (no rebuild, as before).
  set replyTo(TwitchMessage? v) => replyToMsg = v;

  void startReply(TwitchMessage msg) {
    replyToMsg = msg;
    host.markDirty();
    focusNode.requestFocus();
  }

  void clearReply() {
    replyToMsg = null;
    host.markDirty();
  }

  void clearSuggestions() {
    if (suggestions.value.isNotEmpty) suggestions.value = [];
  }

  void invalidateEmoteCache() => _cachedAutocompleteEmotes = null;

  // Channel switch: drop stale suggestions and cached emote list.
  void onChannelChanged() {
    clearSuggestions();
    invalidateEmoteCache();
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
    _checkAutocompleteUndo();

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
      _previousTextForUndo = messageController.text;
      return;
    }
    final channel = host.selectedChannel;
    if (channel == null) {
      _previousTextForUndo = messageController.text;
      return;
    }

    final List<Suggestion> filtered;
    if (isCommand) {
      // All commands are suggested regardless of permissions; the API
      // rejects what the account cannot run (clean error notice shown).
      filtered = filterSuggestions(
        word: word.text,
        emotes: <GenericEmote>[],
        users: const <String>[],
        commands: CommandHandler.allCommands,
      );
    } else {
      final users = userStore.usersForChannel(channel);
      final isMention = word.text.startsWith('@');
      final emotes = isMention
          ? <GenericEmote>[]
          : _cachedAutocompleteEmotes ??= emoteManager.sendableEmotes(channel);
      filtered = filterSuggestions(
        word: filterWord,
        emotes: emotes,
        users: users,
        preferEmotesFirst: host.preferEmotesFirst,
        recentEmoteIds: emoteManager.recentEmoteIds,
      );
    }
    suggestions.value = filtered;
    _previousTextForUndo = messageController.text;
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

    final trailingSpace = wordBefore.end >= textBefore.length
        ? ' '
        : (textBefore[wordBefore.end] == ' ' ? '' : '');

    _lastAutoUndo = (
      start: wordBefore.start,
      originalText: wordBefore.text,
      replacementText: replacement + trailingSpace,
    );

    replaceCurrentWord(messageController, replacement, extendRight: false);

    final replEnd =
        wordBefore.start + replacement.length + trailingSpace.length;
    _undoExpectedAfter = messageController.text.length > replEnd
        ? messageController.text.substring(replEnd)
        : '';

    if (suggestion is EmoteSuggestion) {
      emoteManager.markEmoteUsed(suggestion.emote);
    }
    suggestions.value = [];
    focusNode.requestFocus();
  }

  // Single backspace right after autocomplete restores the typed text.
  // Sequential guards verify no other edits happened in between.
  void _checkAutocompleteUndo() {
    final undo = _lastAutoUndo;
    if (undo == null) return;
    final prev = _previousTextForUndo;
    if (prev == null) return;

    final text = messageController.text;
    final cursor = messageController.selection.baseOffset;
    final replacementLen = undo.replacementText.length;
    final replEnd = undo.start + replacementLen;

    final minLen = text.length < replEnd ? text.length : replEnd;
    for (var i = undo.start; i < minLen; i++) {
      if (text.codeUnitAt(i) !=
          undo.replacementText.codeUnitAt(i - undo.start)) {
        _lastAutoUndo = null;
        _undoExpectedAfter = null;
        return;
      }
    }

    final currentAfter = text.length > replEnd ? text.substring(replEnd) : '';
    final expectedAfter = _undoExpectedAfter ?? '';
    if (currentAfter != expectedAfter) {
      _lastAutoUndo = null;
      _undoExpectedAfter = null;
      return;
    }

    if (text.length != prev.length - 1) return; // single backspace only
    if (cursor != replEnd - 1) return; // cursor right after shortened text

    final regionEnd = replEnd - 1;
    if (text.length < regionEnd) return;
    if (text.substring(undo.start, regionEnd) !=
        undo.replacementText.substring(0, replacementLen - 1)) {
      return;
    }

    final before = text.substring(0, undo.start);
    final after = text.substring(regionEnd);
    _lastAutoUndo = null;
    _undoExpectedAfter = null;
    messageController.value = TextEditingValue(
      text: before + undo.originalText + after,
      selection: TextSelection.collapsed(
        offset: undo.start + undo.originalText.length,
      ),
    );
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
        messageController.clear();
        chatConn.doSendMessage(text, channel);
      } else if (host.whisperTarget != null) {
        _lastSentText = text;
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
    // replies are composed from the Thread tab only.
    if (host.activePanel == OverlayPanel.mentions) return;
    if (host.activePanel == OverlayPanel.thread && host.threadsTabIndex != 0) {
      return;
    }

    // Send gates are soft: the countdown shows as a hint but the message is
    // never held back. Twitch enforces the real block, a successful echo
    // heals a stale self-timeout gate, and a rejection NOTICE re-surfaces it.
    _lastSentText = text;
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
      messageController.text = _lastSentText!;
      messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: messageController.text.length),
      );
      focusNode.requestFocus();
    }
  }

  // Emote picker tap: insert the code at the cursor plus a space.
  void insertEmoteAtCursor(GenericEmote emote) {
    final text = messageController.text;
    final pos = messageController.selection.baseOffset;
    final insertPos = pos.clamp(0, text.length);
    messageController.text =
        '${text.substring(0, insertPos)}${emote.code} ${text.substring(insertPos)}';
    messageController.selection = TextSelection.collapsed(
      offset: insertPos + emote.code.length + 1,
    );
    emoteManager.markEmoteUsed(emote);
  }

  // Input-box send gate ("Slow mode: 12s" / "Timed out: 5s"). Your own
  // timeout wins over the slow-mode window.
  String? cooldownText() {
    final channel = host.selectedChannel;
    if (channel == null || !chatStore.channels.contains(channel)) return null;
    final timeout = chatConn.remainingSelfTimeout(channel);
    if (timeout != null) return 'Timed out: ${formatSeconds(timeout)}';
    final slow = chatConn.remainingSlowCooldown(channel);
    if (slow != null) return 'Slow mode: ${formatSeconds(slow)}';
    return null;
  }

  void refreshCooldown() => cooldownLabel.value = cooldownText();

  bool get enabled =>
      (host.activePanel != OverlayPanel.mentions || host.isWhispersTabActive) &&
      (host.activePanel != OverlayPanel.thread || host.threadsTabIndex == 0) &&
      twitchAuth.isConfigured &&
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
              (_, _, true, _) =>
                host.whisperTarget != null
                    ? 'Whisper to ${host.whisperTarget}...'
                    : 'Type /w <username> <message>',
              (_, OverlayPanel.mentions, _, _) => 'Type a message...',
              _ => null,
            });
}
