import 'dart:convert';

import 'package:http/http.dart' as http;
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';

class RecentMessagesService {
  static const _baseUrl =
      'https://recent-messages.robotty.de/api/v2/recent-messages';

  Future<List<TwitchMessage>> fetchRecent(String channel) async {
    final uri = Uri.parse(
      '$_baseUrl/${Uri.encodeComponent(channel.toLowerCase())}?limit=100',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 10));

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
    String? tagsPart;

    int idx = 0;
    if (raw.startsWith('@')) {
      final space = raw.indexOf(' ');
      if (space == -1) return null;
      tagsPart = raw.substring(1, space);
      idx = space + 1;
    }

    if (idx >= raw.length || raw[idx] != ':') return null;
    final sourceEnd = raw.indexOf(' ', idx);
    if (sourceEnd == -1) return null;
    final source = raw.substring(idx + 1, sourceEnd);
    idx = sourceEnd + 1;

    final cmdEnd = raw.indexOf(' ', idx);
    if (cmdEnd == -1) return null;
    final command = raw.substring(idx, cmdEnd);
    if (command == 'CLEARCHAT') {
      return _parseClearChat(raw, cmdEnd, tagsPart, channel);
    }
    if (command != 'PRIVMSG') return null;
    idx = cmdEnd + 1;

    final targetEnd = raw.indexOf(' ', idx);
    if (targetEnd == -1) return null;
    idx = targetEnd + 1;

    final text = (idx < raw.length && raw[idx] == ':')
        ? raw.substring(idx + 1)
        : raw.substring(idx);

    final tags = _parseTags(tagsPart ?? '');
    final displayName = tags['display-name'] ?? '';
    final color = tags['color'];

    final ircLogin = source.contains('!') ? source.substring(0, source.indexOf('!')) : source;
    final user = TwitchMessage.resolveUser(
      login: ircLogin,
      displayName: displayName.isNotEmpty ? displayName : null,
    );

    final tsMs = tags['rm-received-ts'];
    final messageId = tags['id'];

    String? replyParentId;
    String? replyThreadRootId;
    String? replyUser;
    String? replyText;
    String displayText = text;
    bool isAction = false;
    int offset = 0;
    // IRC ACTION messages are wrapped in \x01ACTION ... \x01
    if (displayText.startsWith('\x01ACTION ') && displayText.endsWith('\x01')) {
      isAction = true;
      displayText = displayText.substring(8, displayText.length - 1);
      offset += 8;
    }
    if (tags.containsKey('reply-parent-msg-id')) {
      replyParentId = tags['reply-parent-msg-id'];
      replyThreadRootId = tags['reply-thread-parent-msg-id'] ?? replyParentId;
      replyUser = tags['reply-parent-display-name'] != null
          ? _unescapeIrcTag(_tryDecodeUri(tags['reply-parent-display-name']!))
          : null;
      replyText = tags['reply-parent-msg-body'] != null
          ? (_unescapeIrcTag(_tryDecodeUri(tags['reply-parent-msg-body']!)))
          : null;
      if (replyUser != null) {
        final prefix = '@$replyUser ';
        if (displayText.startsWith(
          RegExp('^${RegExp.escape(prefix)}', caseSensitive: false),
        )) {
          displayText = displayText.substring(prefix.length);
          offset += prefix.length;
        }
      }
    }

    List<EmotePosition>? emotePositions;
    final emotesTag = tags['emotes'];
    if (emotesTag != null && emotesTag.isNotEmpty) {
      emotePositions = [];
      for (final emoteEntry in emotesTag.split('/')) {
        final colonIdx = emoteEntry.indexOf(':');
        if (colonIdx == -1) continue;
        final emoteId = emoteEntry.substring(0, colonIdx);
        final positionsStr = emoteEntry.substring(colonIdx + 1);
        for (final posStr in positionsStr.split(',')) {
          final dashIdx = posStr.indexOf('-');
          if (dashIdx == -1) continue;
          final start = int.tryParse(posStr.substring(0, dashIdx));
          final end = int.tryParse(posStr.substring(dashIdx + 1));
          if (start == null || end == null) continue;
          // IRC tag positions are relative to the original text. Adjust by
          // offset (chars removed from the front) to match displayText.
          final aStart = start - offset;
          final aEnd = end - offset;
          if (aStart < 0 || aEnd >= displayText.length) continue;
          // end is exclusive, but IRC tag uses inclusive end
          final emoteCode = displayText.substring(aStart, aEnd + 1);
          emotePositions.add(
            EmotePosition(
              emoteId: emoteId,
              startIndex: aStart,
              endIndex: aEnd + 1,
              emoteCode: emoteCode,
            ),
          );
        }
      }
      if (emotePositions.isEmpty) emotePositions = null;
    }

    // Parse source-room-id for shared chat
    final sourceRoomId = tags['source-room-id'];
    final sourceBroadcasterId =
        (sourceRoomId != null && sourceRoomId.isNotEmpty) ? sourceRoomId : null;

    // Parse badges from IRC tags
    List<MessageBadge>? badges;
    final badgesTag = tags['badges'];
    if (badgesTag != null && badgesTag.isNotEmpty) {
      badges = [];
      for (final entry in badgesTag.split(',')) {
        final slashIdx = entry.indexOf('/');
        if (slashIdx == -1) continue;
        final setId = entry.substring(0, slashIdx);
        final versionId = entry.substring(slashIdx + 1);
        if (setId.isNotEmpty && versionId.isNotEmpty) {
          badges.add(MessageBadge(setId: setId, versionId: versionId));
        }
      }
      if (badges.isEmpty) badges = null;
    }

    if (displayName.isEmpty && displayText.isEmpty) return null;

    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    final effectiveColor = (color != null && color.isNotEmpty)
        ? color
        : pickColor(user.login);

    return TwitchMessage(
      login: user.login,
      displayName: user.displayName,
      text: displayText,
      color: effectiveColor,
      timestamp: ts,
      messageId: messageId,
      channel: channel,
      isHistory: true,
      isAction: isAction,
      replyToParentId: replyParentId,
      replyToUser: replyUser,
      replyToText: replyText,
      replyThreadRootId: replyThreadRootId,
      emotePositions: emotePositions,
      badges: badges,
      sourceBroadcasterId: sourceBroadcasterId,
    );
  }

  static TwitchMessage? _parseClearChat(
    String raw,
    int cmdEnd,
    String? tagsPart,
    String? channel,
  ) {
    int idx = cmdEnd + 1;
    final channelEnd = raw.indexOf(' ', idx);
    if (channelEnd == -1) return null;
    idx = channelEnd + 1;
    final targetUser = (idx < raw.length && raw[idx] == ':')
        ? raw.substring(idx + 1)
        : raw.substring(idx);
    if (targetUser.isEmpty) return null;

    final tags = _parseTags(tagsPart ?? '');
    final banDuration = tags['ban-duration'];
    final isTimeout = banDuration != null;
    final durationSec = isTimeout ? int.tryParse(banDuration) : null;

    final text = isTimeout
        ? '$targetUser was timed out${durationSec != null ? ' for ${durationSec}s' : ''}.'
        : '$targetUser was banned.';

    final tsMs = tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: targetUser,
      text: text,
      isSystem: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static String _tryDecodeUri(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  static String _unescapeIrcTag(String raw) {
    return raw
        .replaceAll('\\s', ' ')
        .replaceAll('\\\\', '\\')
        .replaceAll('\\:', ';')
        .replaceAll('\\r', '\r')
        .replaceAll('\\n', '\n');
  }

  static Map<String, String> _parseTags(String tagsStr) {
    if (tagsStr.isEmpty) return {};
    final tags = <String, String>{};
    for (final pair in tagsStr.split(';')) {
      final eq = pair.indexOf('=');
      if (eq == -1) continue;
      tags[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    return tags;
  }
}
