import 'package:flutter/foundation.dart' show visibleForTesting;

import '../client/session.dart';
import '../irc/transport/write.dart' show IrcService;
import '../models/twitch_message.dart';
import 'command_macros.dart';
import 'twitch_auth.dart';
import '../util/text_bypass.dart';

/// Owns the outbound send path and its send gates: macro expansion, slash
/// dispatch, the duplicate-message bypass, and the self-timeout / slow-mode
/// cooldowns the composer reads. The moderation consumers arm and clear the
/// timeout through the verbs here, never by mutating a map.
class ChatSender {
  ChatSender({
    required this.irc,
    required this.session,
    required this.twitchAuth,
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    required this.onSystemMessage,
    required this.slowModeSeconds,
    required this.selfBadges,
    this.getMacros,
    this.onBanner,
    this.onFocusComposer,
    this.onSendStateChanged,
  });

  final IrcService irc;
  final Session session;
  final TwitchAuth twitchAuth;

  /// Slash-command dispatch: the manager owns command handling.
  final void Function(String text, String channel, TwitchAuth auth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final void Function(String channel, String text) onSystemMessage;

  /// The channel's current slow mode in seconds; 0 means off.
  final int Function(String channel) slowModeSeconds;

  /// The sender's own badge set-ids for a channel, for the slow-mode bypass.
  final Set<String> Function(String channel) selfBadges;

  final Map<String, String> Function()? getMacros;
  final void Function(String message)? onBanner;
  final void Function()? onFocusComposer;

  /// Bumped when a send changes composer state (reply cleared) so the input
  /// rebuilds without a full screen setState.
  final void Function()? onSendStateChanged;

  // Self send-gates per channel: when your latest timeout there expires and
  // when you last sent a message (the slow-mode cooldown anchor).
  final _selfTimeoutUntil = <String, DateTime>{};
  final _lastOwnMessageAt = <String, DateTime>{};

  // Last wire text actually sent per channel, for the duplicate bypass.
  final _lastSentWireText = <String, String>{};

  bool _disposed = false;

  // Extra window padded onto both send-gates so a send never slips out while
  // Twitch still considers you blocked: second-granularity countdowns plus
  // local/server clock drift can otherwise expire the gate early.
  static const _sendGrace = Duration(milliseconds: 500);

  // Badge set-ids that bypass slow mode on Twitch.
  static const _slowExemptBadges = {
    'broadcaster',
    'moderator',
    'vip',
    'subscriber',
    'founder',
    'staff',
    'admin',
    'global_mod',
  };

  void dispose() => _disposed = true;

  // ---- Send gates ----------------------------------------------------------

  /// Seconds left on your timeout in [channel], null when none is active.
  /// Ceil-rounded over the padded window, so the display starts one second
  /// high and the gate outlives the raw expiry by the send grace.
  int? remainingSelfTimeout(String channel) {
    final until = _selfTimeoutUntil[channel];
    if (until == null) return null;
    final left = until.add(_sendGrace).difference(DateTime.now());
    if (left <= Duration.zero) {
      _selfTimeoutUntil.remove(channel);
      return null;
    }
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Seconds left before you may send again in [channel] under slow mode,
  /// measured from your own last message. Null when slow mode is off, your
  /// badges bypass it, or the window has elapsed. Ceil-rounded like
  /// [remainingSelfTimeout].
  int? remainingSlowCooldown(String channel) {
    final slow = slowModeSeconds(channel);
    if (slow <= 0 || _bypassesSlowMode(channel)) return null;
    final sentAt = _lastOwnMessageAt[channel];
    if (sentAt == null) return null;
    final left = sentAt
        .add(Duration(seconds: slow))
        .add(_sendGrace)
        .difference(DateTime.now());
    if (left <= Duration.zero) return null;
    return (left.inMilliseconds / 1000).ceil();
  }

  bool _bypassesSlowMode(String channel) =>
      selfBadges(channel).intersection(_slowExemptBadges).isNotEmpty;

  /// Arms the self-timeout gate (own timeout, from either IRC or EventSub).
  void armTimeout(String channel, DateTime until) {
    _selfTimeoutUntil[channel] = until;
  }

  /// Clears the self-timeout gate (unban/untimeout, or an accepted echo).
  void clearTimeout(String channel) => _selfTimeoutUntil.remove(channel);

  // ---- Send ----------------------------------------------------------------

  Future<void> send(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    final auth = twitchAuth;
    final reply = replyTo ?? getReplyToMsg();

    // Local macro triggers expand before anything else: a macro may resolve
    // to a slash command or plain chat text alike.
    final macros = getMacros?.call();
    if (macros != null && macros.isNotEmpty) {
      final expanded = expandMacro(text, macros);
      if (expanded != null) {
        text = expanded;
        onFocusComposer?.call();
      }
    }

    if (text.startsWith('/')) {
      onCommand(text, channel, auth);
      onFocusComposer?.call();
      return;
    }

    if (_disposed) return;
    setReplyToMsg(null);
    onSendStateChanged?.call();
    onFocusComposer?.call();

    final userLogin = session.login;
    if (userLogin == null) {
      onBanner?.call('Connect an account to chat');
      return;
    }

    // Twitch rejects duplicate messages. Mirror DankChat: when the text equals
    // the last wire text we actually sent, toggle a trailing invisible-char
    // suffix on/off so consecutive sends differ on the wire yet look identical.
    // The suffix never accumulates.
    final wireText = bypassTextDuplicate(text, _lastSentWireText[channel]);
    _lastSentWireText[channel] = wireText;

    // Send via the write IRC socket (mirror DankChat). The write socket also
    // JOINs its channels (required to receive their traffic), but a PRIVMSG is
    // valid the moment the socket is up, so there is no join window to gate
    // sends on. The echo of our own message arrives on the read socket, not
    // here. No Helix fallback: if the write socket is down the message cannot
    // be sent, so we surface a notice instead of silently dropping it.
    _lastOwnMessageAt[channel] = DateTime.now();
    if (irc.isConnected) {
      irc.sendMessage(
        channel,
        wireText,
        replyParentMessageId: reply?.messageId,
      );
    } else {
      onSystemMessage(channel, 'Not connected: message not sent');
    }
  }

  // ---- Wire-text bookkeeping -----------------------------------------------

  /// Re-syncs the bypass memory from an own-message echo so it doesn't drift
  /// if the server modified the message (truncation, etc.). Commands are never
  /// compared by the bypass logic, so they are skipped.
  void resyncWireText(String channel, String original) {
    final previous = _lastSentWireText[channel];
    if (previous == null) return;
    if (previous.startsWith('.') || previous.startsWith('/')) return;
    if (stripInvisibleSuffix(previous) != stripInvisibleSuffix(original)) {
      _lastSentWireText[channel] = original;
    }
  }

  /// Drops per-channel send state (channel left).
  void forgetChannel(String channel) {
    _lastSentWireText.remove(channel);
    _selfTimeoutUntil.remove(channel);
    _lastOwnMessageAt.remove(channel);
  }

  /// Drops all send state on an account switch: the gates and the bypass
  /// memory belong to the previous account.
  void clearAccountScope() {
    _lastSentWireText.clear();
    _selfTimeoutUntil.clear();
    _lastOwnMessageAt.clear();
  }

  @visibleForTesting
  void seedWireText(String channel, String text) {
    _lastSentWireText[channel] = text;
  }

  @visibleForTesting
  bool get hasWireText => _lastSentWireText.isNotEmpty;
}
