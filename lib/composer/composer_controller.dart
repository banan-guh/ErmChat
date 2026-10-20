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
    required this.setReplyTo,
    required this.getSelectedChannel,
    required this.isWhispersTabActive,
    required this.whisperTarget,
    required this.activePanel,
    required this.threadsTabIndex,
    required this.openThreadRoot,
    required this.replyToRoot,
    required this.preferEmotesFirst,
    required this.sendSwipeMenu,
    required this.spamIntervalMs,
    required this.computeThreadMessages,
    required this.channelChatReady,
    required this.replayingVod,
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
  final void Function(TwitchMessage?) setReplyTo;
  final String? Function() getSelectedChannel;
  final bool Function() isWhispersTabActive;
  final String? Function() whisperTarget;
  final OverlayPanel Function() activePanel;
  final int Function() threadsTabIndex;
  final TwitchMessage? Function() openThreadRoot;
  final bool Function() replyToRoot;
  final bool Function() preferEmotesFirst;

  /// Swiping up from send opens the spam menu.
  final bool Function() sendSwipeMenu;

  /// The user's spam gap in ms; 0 paces under Twitch's limits.
  final int Function() spamIntervalMs;

  Duration? get _spamGap {
    final ms = spamIntervalMs();
    return ms > 0 ? Duration(milliseconds: ms) : null;
  }

  final List<TwitchMessage> Function() computeThreadMessages;
  final bool Function() channelChatReady;

  /// The selected page replays a VOD's chat, so typing would land in live
  /// chat the viewer is not reading.
  final bool Function() replayingVod;

  bool get _vodBlocks =>
      replayingVod() &&
      activePanel() == OverlayPanel.closed &&
      !isWhispersTabActive();
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

  /// Free width in the island's button row, where room modes ride when
  /// they fit. Zero while no row shows.
  final modeGap = ValueNotifier<double>(0);

  /// Extra width the modes may take under the send column's row part.
  double modeSendRoom = 0;

  /// Whether the selected channel's modes reach under the send column, so
  /// its icon moves up beside the field.
  final modesUnderSend = ValueNotifier<bool>(false);

  String? _lastSentText;
  Timer? _cooldownTickTimer;

  // Repeat-send loop while a finger holds the send menu's spam action.
  Timer? _spamTimer;
  String? _spamText;
  String? _spamChannel;

  /// Bumped on each repeated send, so the spam action can pulse.
  final spamSends = ValueNotifier<int>(0);

  String? get selectedChannel => getSelectedChannel();

  void dispose() {
    _cooldownTickTimer?.cancel();
    focusNode.removeListener(_onInputFocusChanged);
    messageController.removeListener(_onInputChanged);
    messageController.dispose();
    focusNode.dispose();
    suggestions.dispose();
    cooldownLabel.dispose();
    modeGap.dispose();
    modesUnderSend.dispose();
    stopSpam();
    spamSends.dispose();
  }

  void focus() => focusNode.requestFocus();
  void unfocus() => focusNode.unfocus();
  bool get hasFocus => focusNode.hasFocus;

  // Reply state is owned by replyToProvider; this is a plain forwarder.
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

  // Channel switch: drop stale suggestions and the reply, which names a row
  // in the old channel. The emote list itself is read live from the shared
  // mixer per keystroke, so no cache to invalidate.
  void onChannelChanged() {
    autocompleteRevert.clear();
    clearSuggestions();
    setReplyTo(null);
  }

  void onTapClearSuggestions() => suggestions.value = [];

  void toggleEmoteMenu() {
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
      clearSuggestions();
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
    // handler, a leading @name addresses that user, and plain text replies
    // to the latest whisper partner.
    if (isWhispersTabActive()) {
      final addressed = RegExp(
        r'^@(\w+)\s+(\S.*)$',
        dotAll: true,
      ).firstMatch(text);
      final target = addressed?.group(1) ?? whisperTarget();
      final body = addressed?.group(2) ?? text;
      if (text.startsWith('/')) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        chatConn.doSendMessage(text, channel);
      } else if (target != null) {
        _lastSentText = text;
        autocompleteRevert.clear();
        messageController.clear();
        unawaited(
          commandHandler.handle('/w $target $body', channel, twitchAuth),
        );
      } else {
        showNotice(strings().whisperUsageNotice);
      }
      return;
    }

    // Mentions tab stays read-only, as do the threads dashboard lists:
    // replies are composed from the Thread tab only, and only with a thread
    // open. Mod view greys out the global box, except the Terms tab which
    // borrows it for new terms.
    if (activePanel() == OverlayPanel.mentions) return;
    if (activePanel() == OverlayPanel.modView) return;
    if (activePanel() == OverlayPanel.thread &&
        (threadsTabIndex() != 0 || openThreadRoot() == null)) {
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

  bool get _canSpam =>
      enabled && activePanel() == OverlayPanel.closed && !isWhispersTabActive();

  /// Re-sends the field's text, or the last sent text when the field is
  /// empty, to the selected channel at the pace Twitch accepts, until
  /// [stopSpam]. Commands never repeat.
  void startSpam() {
    if (_spamTimer != null || !_canSpam) return;
    final channel = getSelectedChannel();
    final typed = messageController.text.trim();
    final text = typed.isNotEmpty ? typed : _lastSentText;
    if (channel == null || text == null || text.isEmpty) return;
    if (text.startsWith('/')) return;
    _spamText = text;
    _spamChannel = channel;
    _spamTimer = Timer(chatConn.repeatDelay(channel, gap: _spamGap), _spamTick);
  }

  void _spamTick() {
    final channel = _spamChannel;
    final text = _spamText;
    if (channel == null || text == null) return;
    if (!_canSpam || getSelectedChannel() != channel) {
      stopSpam();
      return;
    }
    // The pace can tighten after scheduling (slow mode, a send elsewhere).
    final wait = chatConn.repeatDelay(channel, gap: _spamGap);
    if (wait > Duration.zero) {
      _spamTimer = Timer(wait, _spamTick);
      return;
    }
    _lastSentText = text;
    if (messageController.text.trim() == text) {
      autocompleteRevert.clear();
      messageController.clear();
    }
    chatConn.doSendMessage(text, channel);
    spamSends.value++;
    _spamTimer = Timer(chatConn.repeatDelay(channel, gap: _spamGap), _spamTick);
  }

  void stopSpam() {
    _spamTimer?.cancel();
    _spamTimer = null;
    _spamText = null;
    _spamChannel = null;
  }

  // Long-press send recalls the last sent text for quick re-send/edit.
  void recallLastSent() {
    if (_lastSentText != null && _lastSentText!.isNotEmpty) {
      _draftBeforeRecall = messageController.text;
      autocompleteRevert.clear();
      messageController.text = _lastSentText!;
      messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: messageController.text.length),
      );
      focusNode.requestFocus();
    }
  }

  // The field's text before the last recall, for [undoRecall].
  String? _draftBeforeRecall;

  /// Puts back the draft a recall replaced, while the field still holds the
  /// recalled text: swiping into the send menu after the hold spams the
  /// draft, not the old message.
  void undoRecall() {
    final draft = _draftBeforeRecall;
    _draftBeforeRecall = null;
    if (draft == null || messageController.text != _lastSentText) return;
    autocompleteRevert.clear();
    messageController.text = draft;
    messageController.selection = TextSelection.collapsed(offset: draft.length);
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
      (isWhispersTabActive() || channelChatReady()) &&
      !_vodBlocks;

  /// [withStatus] lets the channel status fill the generic hint; landscape
  /// uses it in place of the status row under the input. [modesInRow]
  /// leaves out the room modes the button row already shows.
  String? hintText({bool withStatus = false, bool modesInRow = false}) =>
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
              _ when _vodBlocks => strings().vodReplayHint,
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
              _ => withStatus ? _channelStatus(modesInRow) : null,
            });

  String? _channelStatus(bool modesInRow) {
    final info = chat.channelFor(getSelectedChannel() ?? '')?.info;
    final status = modesInRow ? info?.stream : info?.status;
    return status == null || status.isEmpty ? null : status;
  }
}
