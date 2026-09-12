import '../../color_utils.dart';
import '../../models/twitch_badge.dart';
import '../../models/twitch_message.dart';
import '../message.dart';

final _replyPrefixRe = RegExp(r'^\s*@\S+\s+');

/// Parses IRC `emotes` tag into [EmotePosition]s. Positions are relative to
/// [originalText]; [prefixLen] adjusts for reply prefix.
List<EmotePosition>? parseIrcEmotePositions(
  String? emotesTag, {
  required String originalText,
  required String strippedText,
  int prefixLen = 0,
}) {
  if (emotesTag == null || emotesTag.isEmpty) return null;
  // ACTION wrapper: Twitch sends emote positions relative to the message
  // body (after "\x01ACTION "), so use the body as the position base.
  final baseText =
      originalText.startsWith('\x01ACTION ') && originalText.endsWith('\x01')
      ? originalText.substring(8)
      : originalText;
  final raw = <({String id, int startCp, int endCp})>[];
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
      raw.add((id: emoteId, startCp: start, endCp: end + 1));
    }
  }
  if (raw.isEmpty) return null;
  final conv = _cpToUtf16Table(baseText);
  int lookup(int cp) => cp >= 0 && cp < conv.length ? conv[cp] : -1;
  final positions = <EmotePosition>[];
  for (final entry in raw) {
    final utf16Start = lookup(entry.startCp);
    final utf16End = lookup(entry.endCp);
    if (utf16Start < 0 || utf16End > baseText.length) continue;
    final emoteCode = baseText.substring(utf16Start, utf16End);
    final adjStart = utf16Start - prefixLen;
    final adjEnd = utf16End - prefixLen;
    if (adjStart < 0 || adjEnd > strippedText.length) continue;
    positions.add(
      EmotePosition(
        emoteId: entry.id,
        startIndex: adjStart,
        endIndex: adjEnd,
        emoteCode: emoteCode,
      ),
    );
  }
  if (positions.isNotEmpty) {
    positions.sort((a, b) => a.startIndex.compareTo(b.startIndex));
  }
  return positions.isEmpty ? null : positions;
}

/// Parses IRC `gifs` tag into [GifAttachment]s. Format per entry:
/// `<start>-<end>|<gifId>|<url>`, entries comma-separated. Positions are
/// relative to [originalText]; [prefixLen] adjusts for reply prefix.
/// URLs are used verbatim and never modified.
List<GifAttachment>? parseIrcGifPositions(
  String? gifsTag, {
  required String originalText,
  required String strippedText,
  int prefixLen = 0,
}) {
  if (gifsTag == null || gifsTag.isEmpty) return null;
  final baseText =
      originalText.startsWith('\x01ACTION ') && originalText.endsWith('\x01')
      ? originalText.substring(8)
      : originalText;
  // Regex scan instead of comma-split: URLs could legally contain commas.
  final entryRe = RegExp(r'(\d+)-(\d+)\|([^|]+)\|(.+?)(?=,\d+-\d+\||$)');
  final matches = entryRe.allMatches(gifsTag).toList();
  if (matches.isEmpty) return null;
  final conv = _cpToUtf16Table(baseText);
  int lookup(int cp) => cp >= 0 && cp < conv.length ? conv[cp] : -1;
  final attachments = <GifAttachment>[];
  for (final m in matches) {
    final start = int.tryParse(m.group(1)!);
    final end = int.tryParse(m.group(2)!);
    final gifId = m.group(3)!;
    final url = m.group(4)!;
    if (start == null || end == null || gifId.isEmpty || url.isEmpty) {
      continue;
    }
    if (!url.startsWith('https://')) continue;
    final utf16Start = lookup(start);
    final utf16End = lookup(end + 1);
    if (utf16Start < 0 || utf16End > baseText.length) continue;
    final adjStart = utf16Start - prefixLen;
    final adjEnd = utf16End - prefixLen;
    if (adjStart < 0 || adjEnd > strippedText.length) continue;
    attachments.add(
      GifAttachment(
        gifId: gifId,
        url: url,
        startIndex: adjStart,
        endIndex: adjEnd,
      ),
    );
  }
  if (attachments.isNotEmpty) {
    attachments.sort((a, b) => a.startIndex.compareTo(b.startIndex));
  }
  return attachments.isEmpty ? null : attachments;
}

/// One-pass table of UTF-16 indices by codepoint offset. Index `cp` holds
/// the UTF-16 index after `cp` code points, so `table[0] == 0` and lookups
/// past the end are out of bounds.
List<int> _cpToUtf16Table(String text) {
  final table = <int>[0];
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    i++;
    // High surrogate: this supplementary character occupies two UTF-16 units.
    if (unit >= 0xD800 && unit <= 0xDBFF && i < text.length) i++;
    table.add(i);
  }
  return table;
}

/// Parses the IRC `badges` tag into [MessageBadge]s.
List<MessageBadge>? parseIrcBadges(String? badgesTag) {
  if (badgesTag == null || badgesTag.isEmpty) return null;
  final badges = <MessageBadge>[];
  for (final entry in badgesTag.split(',')) {
    final slashIdx = entry.indexOf('/');
    if (slashIdx == -1) continue;
    final setId = entry.substring(0, slashIdx);
    final versionId = entry.substring(slashIdx + 1);
    if (setId.isNotEmpty && versionId.isNotEmpty) {
      badges.add(MessageBadge(setId: setId, versionId: versionId));
    }
  }
  return badges.isEmpty ? null : badges;
}

/// Parses an IRC PRIVMSG into a [TwitchMessage]. Defaults fill in for own
/// echoes; timestamp/isHistory override for history.
TwitchMessage parseIrcChatMessage(
  IrcMessage ircMsg, {
  required String? channel,
  String? defaultLogin,
  String? defaultDisplayName,
  String? defaultUserId,
  DateTime? timestamp,
  bool isHistory = false,
}) {
  final displayName =
      ircMsg.tags['display-name']?.trim() ?? defaultDisplayName ?? '';
  final ircPrefLogin = ircMsg.prefix != null && ircMsg.prefix!.contains('!')
      ? ircMsg.prefix!.substring(0, ircMsg.prefix!.indexOf('!'))
      : null;
  final user = TwitchMessage.resolveUser(
    login: ircPrefLogin ?? defaultLogin ?? displayName,
    displayName: displayName.isNotEmpty ? displayName : null,
  );

  final messageId = ircMsg.tags['id'] ?? ircMsg.tags['message-id'];
  // Text is in trailing; no-colon messages use param[1].
  final text =
      ircMsg.trailing ?? (ircMsg.params.length > 1 ? ircMsg.params[1] : '');
  final ircReplyParentId = ircMsg.tags['reply-parent-msg-id'];
  final ircReplyThreadRootId =
      ircMsg.tags['reply-thread-parent-msg-id'] ?? ircReplyParentId;

  // IRC ACTION messages (/me) are wrapped in \x01ACTION ... \x01.
  var isAction = false;
  String strippedText = text;
  var prefixLen = 0;
  if (strippedText.startsWith('\x01ACTION ') && strippedText.endsWith('\x01')) {
    isAction = true;
    strippedText = strippedText.substring(8, strippedText.length - 1);
    // Emote positions are relative to the ACTION body, not the wrapper.
  }

  // Strip "@username " prefix from reply echoes; adjust emote positions by
  // prefixLen.
  if (ircReplyParentId != null) {
    final prefixMatch = _replyPrefixRe.firstMatch(strippedText);
    if (prefixMatch != null) {
      prefixLen += prefixMatch.end;
      strippedText = strippedText.substring(prefixMatch.end);
    }
  }
  final ircReplyUser = ircMsg.tags['reply-parent-display-name'];
  final ircReplyText = ircMsg.tags['reply-parent-msg-body'];

  final tsMs = ircMsg.tags['tmi-sent-ts'];
  final effectiveTimestamp =
      timestamp ??
      (tsMs != null
          ? DateTime.fromMillisecondsSinceEpoch(
              int.tryParse(tsMs) ??
                  DateTime.now().toUtc().millisecondsSinceEpoch,
              isUtc: true,
            )
          : DateTime.now().toUtc());

  final userId = ircMsg.tags['user-id'] ?? defaultUserId;
  final color = ircMsg.tags['color'] != null && ircMsg.tags['color']!.isNotEmpty
      ? ircMsg.tags['color']!
      : pickColor(user.login);

  // source-room-id != room-id means mirrored (foreign) message.
  final sourceRoomId = ircMsg.tags['source-room-id'];
  final sourceBroadcasterId =
      (sourceRoomId != null &&
          sourceRoomId.isNotEmpty &&
          sourceRoomId != ircMsg.tags['room-id'])
      ? sourceRoomId
      : null;
  // source-id: stable across mirrored copies; `id` is room-local.
  final sourceMessageId = ircMsg.tags['source-id'];

  // Bits tag highlights like sub notices.
  final bitsAmount = int.tryParse(ircMsg.tags['bits'] ?? '');

  // Tags for ping evaluation: msg-id, custom-reward-id,
  // pinned-chat-paid-amount.
  final msgId = ircMsg.tags['msg-id'];
  final customRewardId = ircMsg.tags['custom-reward-id'];
  final pinnedPaidAmount = ircMsg.tags['pinned-chat-paid-amount'];

  return TwitchMessage(
    login: user.login,
    displayName: user.displayName,
    text: strippedText,
    channel: channel,
    messageId: messageId,
    timestamp: effectiveTimestamp,
    userId: userId,
    color: color,
    isAction: isAction,
    replyToParentId: ircReplyParentId,
    replyToUser: ircReplyUser,
    replyToText: ircReplyText,
    replyThreadRootId: ircReplyThreadRootId,
    emotePositions: parseIrcEmotePositions(
      ircMsg.tags['emotes'],
      originalText: text,
      strippedText: strippedText,
      prefixLen: prefixLen,
    ),
    gifAttachments: parseIrcGifPositions(
      ircMsg.tags['gifs'],
      originalText: text,
      strippedText: strippedText,
      prefixLen: prefixLen,
    ),
    badges: parseIrcBadges(ircMsg.tags['badges']),
    sourceBroadcasterId: sourceBroadcasterId,
    sourceMessageId:
        (sourceBroadcasterId != null &&
            sourceMessageId != null &&
            sourceMessageId.isNotEmpty)
        ? sourceMessageId
        : null,
    isFirstMessage: ircMsg.tags['first-msg'] == '1',
    msgId: msgId,
    customRewardId: customRewardId,
    pinnedPaidAmount: pinnedPaidAmount,
    bitsAmount: bitsAmount,
    systemAccent: bitsAmount != null ? announcementColors['PRIMARY'] : null,
    isHistory: isHistory,
  );
}
