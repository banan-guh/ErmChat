import 'dart:convert';

import 'package:http/http.dart' as http;
import '../util/constants.dart';
import '../models/twitch_message.dart';
import '../util/irc_utils.dart';
import '../color_utils.dart';
import 'twitch_irc.dart';

class RecentMessagesService {
  static const _baseUrl =
      'https://recent-messages.robotty.de/api/v2/recent-messages';

  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/${Uri.encodeComponent(channel.toLowerCase())}'
      '?limit=${limit.clamp(1, 500)}',
    );
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
    for (final raw in rawMessages) {
      final parsed = parseIrcLine(raw as String, channel: channel);
      if (parsed != null) messages.add(parsed);
    }

    for (final msg in messages) {
      if (msg.isSystem && msg.login.isNotEmpty) {
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

    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
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
      default:
        return null;
    }
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
    final targetUser = msg.trailing;
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
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parseUserNotice(IrcMessage msg, String? channel) {
    final msgId = msg.tags['msg-id'] ?? '';
    if (msgId.isEmpty) return null;
    // Only announcements carry a meaningful login (enables the "You
    // announced" replacement); other notices keep it empty so the ban
    // deletion sweep in fetchRecent never treats them as ban targets.
    final isAnnouncement = msgId == 'announcement';
    final login = isAnnouncement ? (msg.tags['login'] ?? '') : '';
    final displayName = msg.tags['display-name'] ?? login;
    final systemMsg =
        msg.tags['system-msg'] != null && msg.tags['system-msg']!.isNotEmpty
        ? unescapeIrcTag(msg.tags['system-msg']!)
        : null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: login,
      text: buildUserNoticeText(
        msgId: msgId,
        displayName: displayName,
        systemMsg: systemMsg,
        text: msg.trailing,
      ),
      isSystem: true,
      systemAccent: isAnnouncement
          ? announcementColorFor(msg.tags['msg-param-color'])
          : null,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }
}
