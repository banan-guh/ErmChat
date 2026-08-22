import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../util/constants.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';
import '../util/log.dart';
import 'twitch_irc.dart';

class RecentMessagesService {
  static const _baseUrl =
      'https://recent-messages.robotty.de/api/v2/recent-messages';
  // Mirror of the same service (robotty/recent-messages2) hosted by zneix.
  // Falls back here when the primary is unavailable (5xx / network error).
  static const _mirrorBaseUrl =
      'https://recent-messages.zneix.eu/api/v2/recent-messages';

  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    final path =
        '/${Uri.encodeComponent(channel.toLowerCase())}'
        '?limit=${limit.clamp(1, 800)}';
    try {
      return await _fetchFrom('$_baseUrl$path', channel);
    } catch (primaryError) {
      logDebug(
        '[RecentMessages] primary fetch failed ($primaryError) - '
        'trying mirror',
      );
      return _fetchFrom('$_mirrorBaseUrl$path', channel);
    }
  }

  Future<List<TwitchMessage>> _fetchFrom(String url, String channel) async {
    final uri = Uri.parse(url);
    final res = await http.get(uri).timeout(httpTimeout);

    if (res.statusCode != 200) {
      throw Exception(
        'error ${res.statusCode}: ${res.reasonPhrase ?? "unknown"}',
      );
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final rawMessages = body['messages'] as List<dynamic>?;
    if (rawMessages == null || rawMessages.isEmpty) return [];

    final messages = <TwitchMessage>[];
    final clearMsgTargets = <String>{};
    for (final raw in rawMessages) {
      final rawLine = raw as String;
      // CLEARMSG lines don't render themselves; they mark the target
      // message as deleted (applied after the batch is parsed).
      final target = clearMsgTargetId(rawLine);
      if (target != null) {
        clearMsgTargets.add(target);
        continue;
      }
      // Announcement USERNOTICEs render as two entries, like the live view:
      // the child message (announcement text as a normal message) followed
      // by the "Announcement" label. Sub/resub notices with a user message
      // do the same so emotes render in the child.
      final child = parseAnnouncementChild(rawLine, channel: channel);
      if (child != null) messages.add(child);
      final subChild = parseSubChild(rawLine, channel: channel);
      if (subChild != null) messages.add(subChild);
      final parsed = parseIrcLine(rawLine, channel: channel);
      if (parsed != null) messages.add(parsed);
    }

    // Only ban/timeout system messages sweep prior messages from the
    // target user; announcements carry a login too but must not delete
    // anything.
    applyBanSweep(messages);
    applyMessageDeletions(messages, clearMsgTargets);

    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  /// Extracts the deleted message id from a CLEARMSG history line, or null.
  @visibleForTesting
  static String? clearMsgTargetId(String raw) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'CLEARMSG') return null;
    final target = msg.tags['target-msg-id'];
    return (target == null || target.isEmpty) ? null : target;
  }

  /// Marks messages deleted by CLEARMSG history lines (deletions must
  /// survive a restart like every other event).
  @visibleForTesting
  static void applyMessageDeletions(
    List<TwitchMessage> messages,
    Iterable<String> targetIds,
  ) {
    final targets = targetIds.toSet();
    if (targets.isEmpty) return;
    for (final msg in messages) {
      if (!msg.isSystem &&
          msg.messageId != null &&
          targets.contains(msg.messageId)) {
        msg.deleted = true;
      }
    }
  }

  /// Marks messages deleted when a later ban/timeout system message targets
  /// the same login. Exposed for tests; `isBanNotice` keeps announcements
  /// (which legitimately carry a login) out of the sweep.
  @visibleForTesting
  static void applyBanSweep(List<TwitchMessage> messages) {
    for (final msg in messages) {
      if (msg.isBanNotice && msg.login.isNotEmpty) {
        final targetUser = msg.login;
        for (final other in messages) {
          if (!other.isSystem &&
              other.login == targetUser &&
              !msg.timestamp.isBefore(other.timestamp)) {
            other.deleted = true;
          }
        }
      }
    }
  }

  static TwitchMessage? parseIrcLine(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null) return null;
    switch (msg.command) {
      case 'PRIVMSG':
        return _parsePrivmsg(msg, channel);
      case 'CLEARCHAT':
        return _parseClearChat(msg, channel);
      case 'USERNOTICE':
        return _parseUserNotice(msg, channel);
      case 'NOTICE':
        return _parseNotice(msg, channel);
      default:
        return null;
    }
  }

  static TwitchMessage? _parseNotice(IrcMessage msg, String? channel) {
    final text = msg.trailing;
    if (text == null || text.isEmpty) return null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: '',
      text: text,
      isSystem: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parsePrivmsg(IrcMessage msg, String? channel) {
    final tsMs = msg.tags['rm-received-ts'];
    final timestamp = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : null;

    final parsed = parseIrcChatMessage(
      msg,
      channel: channel,
      timestamp: timestamp,
      isHistory: true,
    );

    // Lines with neither a display name nor any text are junk.
    final rawDisplayName = msg.tags['display-name'] ?? '';
    if (rawDisplayName.isEmpty && parsed.text.isEmpty) return null;
    return parsed;
  }

  static TwitchMessage? _parseClearChat(IrcMessage msg, String? channel) {
    // Robotty strips the trailing colon for single-word payloads.
    final targetUser =
        msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null);
    if (targetUser == null || targetUser.isEmpty) return null;

    final banDuration = msg.tags['ban-duration'];
    final isTimeout = banDuration != null;
    final durationSec = isTimeout ? int.tryParse(banDuration) : null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: targetUser,
      text: buildBanText(
        user: targetUser,
        isTimeout: isTimeout,
        durationSec: durationSec,
      ),
      isSystem: true,
      isBanNotice: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parseUserNotice(IrcMessage msg, String? channel) {
    final msgId = msg.tags['msg-id'] ?? '';
    if (msgId.isEmpty) return null;
    // Only announcements carry a meaningful login; other notices keep it
    // empty so the ban deletion sweep in fetchRecent never treats them as
    // ban targets (the sweep also keys on isBanNotice, so this is belt and
    // braces).
    final isAnnouncement = msgId == 'announcement';
    final login = isAnnouncement ? (msg.tags['login'] ?? '') : '';
    final displayName = msg.tags['display-name'] ?? login;
    final systemMsg =
        msg.tags['system-msg'] != null && msg.tags['system-msg']!.isNotEmpty
        ? msg.tags['system-msg']
        : null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();
    // Robotty strips the trailing colon for single-word payloads.
    final text = msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null);
    final isSubWithText =
        (msgId == 'sub' || msgId == 'resub') &&
        (text?.trim().isNotEmpty ?? false);

    return TwitchMessage(
      login: login,
      text: buildUserNoticeText(
        msgId: msgId,
        displayName: displayName,
        systemMsg: systemMsg,
      ),
      isSystem: true,
      // Announcements carry their banner accent; subscriptions / gift subs /
      // watch streaks highlight like a default (PRIMARY) purple announcement
      // (DankChat-style).
      systemAccent: isAnnouncement
          ? announcementColorFor(msg.tags['msg-param-color']) ??
                announcementColors['PRIMARY']
          : subNoticeMsgIds.contains(msgId)
          ? announcementColors['PRIMARY']
          : null,
      channel: channel,
      // 1ms after the child message so the sorted history keeps the child
      // above the label (List.sort is not stable).
      timestamp: isAnnouncement || isSubWithText
          ? ts.add(const Duration(milliseconds: 1))
          : ts,
      isHistory: true,
    );
  }

  /// The child chat message for a sub/resub USERNOTICE line that carries a
  /// user message (the message rendered as a normal chat message so emotes
  /// render), or null when the line is not a sub/resub with text.
  @visibleForTesting
  static TwitchMessage? parseSubChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'USERNOTICE') return null;
    final msgId = msg.tags['msg-id'];
    if (msgId != 'sub' && msgId != 'resub') return null;
    // Robotty strips the trailing colon for single-word payloads.
    final text =
        (msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null))
            ?.trim();
    if (text == null || text.isEmpty) return null;

    final login = (msg.tags['login'] ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: login,
      displayName: displayName,
      text: text,
      color: msg.tags['color'],
      userId: msg.tags['user-id'],
      messageId: msg.tags['id'],
      badges: parseIrcBadges(msg.tags['badges']),
      emotePositions: parseIrcEmotePositions(
        msg.tags['emotes'],
        originalText: text,
        strippedText: text,
      ),
      systemAccent: announcementColors['PRIMARY'],
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  /// The child chat message for an announcement USERNOTICE line (the
  /// announcement text rendered as a normal message, DankChat-style), or
  /// null when the line is not an announcement with text.
  @visibleForTesting
  static TwitchMessage? parseAnnouncementChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'USERNOTICE') return null;
    if (msg.tags['msg-id'] != 'announcement') return null;
    // Robotty strips the trailing colon for single-word payloads.
    final text =
        (msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null))
            ?.trim();
    if (text == null || text.isEmpty) return null;

    final login = (msg.tags['login'] ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: login,
      displayName: displayName,
      text: text,
      color: msg.tags['color'],
      userId: msg.tags['user-id'],
      messageId: msg.tags['id'],
      badges: parseIrcBadges(msg.tags['badges']),
      emotePositions: parseIrcEmotePositions(
        msg.tags['emotes'],
        originalText: text,
        strippedText: text,
      ),
      systemAccent:
          announcementColorFor(msg.tags['msg-param-color']) ??
          announcementColors['PRIMARY'],
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }
}
