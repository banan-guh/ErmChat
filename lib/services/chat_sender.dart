import 'package:flutter/foundation.dart' show visibleForTesting;

import '../client/session.dart';
import '../l10n/l10n.dart';
import '../irc/transport/write.dart' show IrcService;
import '../models/twitch_message.dart';
import 'command_macros.dart';
import 'twitch_auth.dart';
import '../util/chat_text.dart';
import '../util/fake_history.dart';

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
    this.onMessageSent,
    this.strings = englishStrings,
    this.now = DateTime.now,
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

  /// A chat line went out on the wire (not commands).
  final void Function(String channel)? onMessageSent;
  final AppLocalizations Function() strings;

  /// Clock for the send gates.
  final DateTime Function() now;

  // Self send-gates per channel: when your latest timeout there expires and
  // when Twitch last accepted one of your messages (the slow-mode cooldown
  // anchor).
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

  /// Repeat gaps that stay under Twitch's limits, with a margin: plain
  /// accounts, and broadcaster/mod/VIP.
  static const plainRepeatGap = Duration(milliseconds: 1600);
  static const privilegedRepeatGap = Duration(milliseconds: 330);

  // Badge set-ids that lift Twitch's chat rate limit from 20 to 100 messages
  // per 30 seconds.
  static const _rateExemptBadges = {'broadcaster', 'moderator', 'vip'};

  // Own sends in the last 30 seconds, every channel, for repeat pacing.
  final _recentSends = <DateTime>[];
  static const _rateWindow = Duration(seconds: 30);

  void dispose() => _disposed = true;

  // ---- Send gates ----------------------------------------------------------

  /// Seconds left on your timeout in [channel], null when none is active.
  /// Ceil-rounded over the padded window, so the display starts one second
  /// high and the gate outlives the raw expiry by the send grace.
  int? remainingSelfTimeout(String channel) {
    final until = _selfTimeoutUntil[channel];
    if (until == null) return null;
    final left = until.add(_sendGrace).difference(now());
    if (left <= Duration.zero) {
      _selfTimeoutUntil.remove(channel);
      return null;
    }
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Seconds left before you may send again in [channel] under slow mode,
  /// measured from your own last accepted message. Null when slow mode is off,
  /// your badges bypass it, or the window has elapsed. Ceil-rounded without
  /// the send grace: the hint should read the channel's exact delay.
  int? remainingSlowCooldown(String channel) {
    final slow = slowModeSeconds(channel);
    if (slow <= 0 || _bypassesSlowMode(channel)) return null;
    final sentAt = _lastOwnMessageAt[channel];
    if (sentAt == null) return null;
    final left = sentAt.add(Duration(seconds: slow)).difference(now());
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

  /// Anchors the slow-mode window to a message Twitch actually accepted. The
  /// echo is the only signal a send went through, so rejected attempts never
  /// reset the countdown. Called from the ingestion own-echo path.
  void noteOwnMessageSent(String channel) => _lastOwnMessageAt[channel] = now();

  /// Wait before the next repeated send to [channel] stays under Twitch's
  /// limits: 20 messages per 30 seconds and one per second per channel, or
  /// 100 per 30 seconds with a privileged badge, plus slow mode. Overrunning
  /// the plain limit silences the account for an hour, so each carries a
  /// margin. A gap the user chose for the role replaces that pacing, slow
  /// mode aside: [gap] for a plain account, [privilegedGap] with a privileged
  /// badge. Zero when a send may go now.
  Duration repeatDelay(
    String channel, {
    Duration? gap,
    Duration? privilegedGap,
  }) {
    final at = now();
    _recentSends.removeWhere((t) => at.difference(t) >= _rateWindow);
    final privileged = selfBadges(
      channel,
    ).intersection(_rateExemptBadges).isNotEmpty;
    final chosen = privileged ? privilegedGap : gap;
    var wait = Duration.zero;
    void atLeast(Duration d) {
      if (d > wait) wait = d;
    }

    // Windowed budget: the oldest send that must age out first.
    final budget = privileged ? 95 : 18;
    if (chosen == null && _recentSends.length >= budget) {
      final oldest = _recentSends[_recentSends.length - budget];
      atLeast(oldest.add(_rateWindow).difference(at));
    }
    if (_recentSends.isNotEmpty) {
      final step =
          chosen ?? (privileged ? privilegedRepeatGap : plainRepeatGap);
      atLeast(_recentSends.last.add(step).difference(at));
    }
    final slow = remainingSlowCooldown(channel);
    if (slow != null) atLeast(Duration(seconds: slow) + _sendGrace);
    return wait;
  }

  // ---- Send ----------------------------------------------------------------

  Future<void> send(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    if (FakeHistory.isFake(channel)) return;
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
      onBanner?.call(strings().connectAccountToChat);
      return;
    }

    // Twitch rejects duplicate messages. Mirror DankChat: when the text equals
    // the last wire text we actually sent, toggle a trailing invisible-char
    // suffix on/off so consecutive sends differ on the wire yet look identical.
    // The suffix never accumulates.
    final wireText = bypassTextDuplicate(text, _lastSentWireText[channel]);

    // Send via the write IRC socket (mirror DankChat). The write socket also
    // JOINs its channels (required to receive their traffic), but a PRIVMSG is
    // valid the moment the socket is up, so there is no join window to gate
    // sends on. The echo of our own message arrives on the read socket, not
    // here. No Helix fallback: if the write socket is down the message cannot
    // be sent, so we surface a notice instead of silently dropping it.
    if (irc.isConnected) {
      _lastSentWireText[channel] = wireText;
      _recentSends.add(now());
      irc.sendMessage(
        channel,
        wireText,
        replyParentMessageId: reply?.messageId,
      );
      onMessageSent?.call(channel);
    } else {
      onSystemMessage(channel, strings().notConnectedNotSent);
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
    _recentSends.clear();
  }

  @visibleForTesting
  void seedWireText(String channel, String text) {
    _lastSentWireText[channel] = text;
  }

  @visibleForTesting
  bool get hasWireText => _lastSentWireText.isNotEmpty;
}
