import 'dart:convert';

import '../archive/archive_row.dart';
import '../archive/archive_users.dart';
import '../color_utils.dart';
import '../models/twitch_badge.dart';
import '../emotes/emote.dart';
import '../models/twitch_message.dart';
import 'emote_store.dart';

/// Maps [TwitchMessage] to the codec's [ArchiveRow] and back. The codec cannot
/// import models, so this lives in the pipeline layer. Identity and look go
/// through the channel's interned [UserTables].
///
/// Fields without a codec column ride in `extraTags` under `x-` keys:
/// reply body, system accent, redemption image and points, and gifs.
/// Third-party emote tokens are stored as they were parsed on arrival, with
/// each emote's definition kept once per channel (`emote_defs`), so history
/// shows the emotes of its time. Highlights are session state.
class ArchiveAdapter {
  const ArchiveAdapter(this.users);

  final UserTables users;

  static const _replyBody = 'x-reply-body';
  static const _accent = 'x-accent';
  static const _redeemImage = 'x-redeem-image';
  static const _redeemPoints = 'x-redeem-points';
  static const _gifs = 'x-gifs';

  /// Key of [e]'s stored definition: provider, id and code, so a renamed
  /// alias stays its own version.
  static String defKey(Emote e) => '${e.type.name}:${e.id}:${e.code}';

  /// [m]'s third-party emotes, when its tokens are final: parsed against
  /// complete catalogs. Null otherwise; such a row parses again on read.
  static List<EmoteToken>? storedTokens(TwitchMessage m) {
    final tokens = m.emoteTokens;
    if (m.isSystem || tokens == null || m.emotesPartial) return null;
    return [
      for (final t in tokens)
        if (t.emote case final e? when e.type != EmoteType.twitch) t,
    ];
  }

  ArchiveRow toRow(TwitchMessage m) {
    final who = users.internWho(
      Who(
        userId: m.userId ?? '',
        login: m.login,
        displayName: m.displayName == m.login ? null : m.displayName,
      ),
    );
    final look = users.internLook(
      Look(
        color: m.color,
        badges: [
          for (final b in m.badges ?? const <MessageBadge>[])
            '${b.setId}/${b.versionId}',
        ].join(','),
      ),
    );
    final gifs = m.gifAttachments;
    final accent = m.systemAccent;
    final replyBody = m.replyToText;
    final tokens = storedTokens(m);
    return ArchiveRow(
      timestampMs: m.timestamp.millisecondsSinceEpoch,
      text: m.text,
      user: users.internState(who, look),
      isSystem: m.isSystem,
      isAction: m.isAction,
      isBanNotice: m.isBanNotice,
      deleted: m.deleted,
      isFirstMessage: m.isFirstMessage,
      isBackfill: m.isBackfill,
      isHistory: m.isHistory,
      messageId: m.messageId,
      replyParentId: m.replyToParentId,
      threadRootId: m.replyThreadRootId,
      replyToUser: m.replyToUser,
      msgId: m.msgId,
      customRewardId: m.customRewardId,
      bitsAmount: m.bitsAmount,
      pinnedPaidAmount: m.pinnedPaidAmount,
      sourceBroadcasterId: m.sourceBroadcasterId,
      sourceMessageId: m.sourceMessageId,
      emotes: [
        for (final e in m.emotePositions ?? const <EmotePosition>[])
          ArchiveEmote(e.emoteId, e.startIndex, e.endIndex),
      ],
      tokensStored: tokens != null,
      tokens: [
        for (final t in tokens ?? const <EmoteToken>[])
          ArchiveToken(defKey(t.emote!), t.start, t.end),
      ],
      extraTags: [
        if (replyBody != null) (_replyBody, replyBody),
        if (accent != null) (_accent, '${accent.toARGB32()}'),
        if (m.redemptionImageUrl != null) (_redeemImage, m.redemptionImageUrl!),
        if (m.redemptionPoints != null)
          (_redeemPoints, '${m.redemptionPoints}'),
        if (gifs != null && gifs.isNotEmpty)
          (_gifs, jsonEncode([for (final g in gifs) g.toJson()])),
      ],
    );
  }

  /// Rebuilds a message for [channel]. [asHistory] marks restored rows so
  /// they never count unread, mentions, or TTS. [defs] holds the emote
  /// definitions of stored tokens by key; a row missing one parses again.
  TwitchMessage fromRow(
    ArchiveRow r,
    String channel, {
    bool asHistory = false,
    Map<String, Emote> defs = const {},
  }) {
    final state = users.states[r.user];
    final who = users.whos[state.who];
    final look = users.looks[state.look];
    final extra = {for (final (k, v) in r.extraTags) k: v};
    final gifs = extra[_gifs];
    final accent = int.tryParse(extra[_accent] ?? '');
    final positions = r.emotes.isEmpty ? null : _positions(r);
    return TwitchMessage(
      login: who.login,
      displayName: who.displayName ?? who.login,
      userId: who.userId.isEmpty ? null : who.userId,
      text: r.text,
      color: look.color,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        r.timestampMs,
        isUtc: true,
      ),
      isSystem: r.isSystem,
      systemAccent: accent == null ? null : Color(accent),
      isAction: r.isAction,
      isBanNotice: r.isBanNotice,
      messageId: r.messageId,
      channel: channel,
      deleted: r.deleted,
      isHistory: asHistory || r.isHistory,
      isBackfill: r.isBackfill,
      replyToParentId: r.replyParentId,
      replyToUser: r.replyToUser,
      replyToText: extra[_replyBody],
      replyThreadRootId: r.threadRootId,
      isFirstMessage: r.isFirstMessage,
      msgId: r.msgId,
      customRewardId: r.customRewardId,
      redemptionImageUrl: extra[_redeemImage],
      redemptionPoints: int.tryParse(extra[_redeemPoints] ?? ''),
      pinnedPaidAmount: r.pinnedPaidAmount,
      bitsAmount: r.bitsAmount,
      emotePositions: positions,
      gifAttachments: gifs == null
          ? null
          : [
              for (final g in jsonDecode(gifs) as List)
                GifAttachment.fromJson(Map<String, dynamic>.from(g as Map)),
            ],
      badges: look.badges.isEmpty ? null : _badges(look.badges),
      sourceBroadcasterId: r.sourceBroadcasterId,
      sourceMessageId: r.sourceMessageId,
    )..emoteTokens = _tokens(r, positions, defs);
  }

  /// The row's emotes as first parsed: Twitch ones from their positions, the
  /// rest from their stored definitions, through the live tokenizer. Null
  /// sends the row through a fresh parse.
  static List<EmoteToken>? _tokens(
    ArchiveRow r,
    List<EmotePosition>? positions,
    Map<String, Emote> defs,
  ) {
    if (!r.tokensStored) return null;
    final byCode = <String, Emote>{};
    for (final t in r.tokens) {
      final emote = defs[t.key];
      if (emote == null ||
          t.start < 0 ||
          t.end > r.text.length ||
          t.start > t.end) {
        return null;
      }
      byCode[r.text.substring(t.start, t.end)] = emote;
    }
    return [
      for (final token in EmoteStore.tokenize(
        text: r.text,
        positions: positions,
        byCode: byCode,
      ))
        if (token.isEmote) token,
    ];
  }

  /// The emote code is the text slice, so it is not stored.
  static List<EmotePosition> _positions(ArchiveRow r) => [
    for (final e in r.emotes)
      EmotePosition(
        emoteId: e.id,
        startIndex: e.start,
        endIndex: e.end,
        emoteCode: e.start >= 0 && e.start <= e.end && e.end <= r.text.length
            ? r.text.substring(e.start, e.end)
            : '',
      ),
  ];

  static List<MessageBadge> _badges(String combo) => [
    for (final part in combo.split(','))
      if (part.contains('/'))
        MessageBadge(
          setId: part.substring(0, part.indexOf('/')),
          versionId: part.substring(part.indexOf('/') + 1),
        ),
  ];
}
