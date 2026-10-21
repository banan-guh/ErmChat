import 'dart:convert';

import '../archive/archive_row.dart';
import '../archive/archive_users.dart';
import '../color_utils.dart';
import '../models/twitch_badge.dart';
import '../emotes/emote.dart';
import '../models/twitch_message.dart';
import 'emote_store.dart';
import 'set_history.dart';

/// Maps [TwitchMessage] to the codec's [ArchiveRow] and back. The codec cannot
/// import models, so this lives in the pipeline layer. Identity and look go
/// through the channel's interned [UserTables].
///
/// Fields without a codec column ride in `extraTags` under `x-` keys:
/// reply body, system accent, redemption image and points, and gifs.
/// Third-party emotes are drawn on read from the channel's emote sets at
/// the row's time ([ChannelSets]). Only what those cannot tell is stored:
/// the sender's personal 7TV emotes, and every emote of a shared-chat row,
/// whose sets belong to another channel. Each stored emote's definition is
/// kept once per channel (`emote_defs`). Highlights are session state.
class ArchiveAdapter {
  const ArchiveAdapter(this.users);

  final UserTables users;

  static const _replyBody = 'x-reply-body';
  static const _accent = 'x-accent';
  static const _redeemImage = 'x-redeem-image';
  static const _redeemPoints = 'x-redeem-points';
  static const _gifs = 'x-gifs';

  // Stands in for a user a damaged row points past.
  static final _unknown = Who(userId: '', login: '');

  /// The emotes of [m] the sets cannot tell (see [ArchiveAdapter]), or null
  /// when there are none to store yet. A shared-chat row stores all its
  /// third-party emotes once they are final.
  static List<EmoteToken>? storedTokens(TwitchMessage m) {
    final tokens = m.emoteTokens;
    if (m.isSystem || tokens == null) return null;
    final shared = m.sourceBroadcasterId != null;
    if (shared && m.emotesPartial) return null;
    return [
      for (final t in tokens)
        if (t.emote case final e?
            when e.type != EmoteType.twitch &&
                (shared || e.scope == EmoteScope.personal))
          t,
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
    final sent = m.sent;
    final gifs = sent == null ? m.gifAttachments : sent.gifs;
    final accent = m.systemAccent;
    final replyBody = m.replyToText;
    final tokens = storedTokens(m);
    return ArchiveRow(
      timestampMs: m.timestamp.millisecondsSinceEpoch,
      text: sent?.text ?? m.text,
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
        for (final e
            in (sent == null ? m.emotePositions : sent.positions) ??
                const <EmotePosition>[])
          ArchiveEmote(e.emoteId, e.startIndex, e.endIndex),
      ],
      tokensStored: tokens != null && m.sourceBroadcasterId != null,
      tokens: [
        for (final t in tokens ?? const <EmoteToken>[])
          ArchiveToken(SetHistory.emoteKey(t.emote!), t.start, t.end),
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
  /// they never count unread, mentions, or TTS. [defs] holds the stored
  /// emote definitions by key, and [sets] the channel's emote and badge
  /// sets; without either the row parses against today's sets on render.
  /// [rewrite] applies today's keyword rules to the text as sent.
  TwitchMessage fromRow(
    ArchiveRow r,
    String channel, {
    bool asHistory = false,
    Map<String, Emote> defs = const {},
    ChannelSets? sets,
    void Function(TwitchMessage msg)? rewrite,
  }) {
    final state = users.states[r.user];
    final who = users.whos[state?.who] ?? _unknown;
    final look = users.looks[state?.look] ?? const Look();
    final extra = {for (final (k, v) in r.extraTags) k: v};
    final gifs = extra[_gifs];
    final accent = int.tryParse(extra[_accent] ?? '');
    final positions = r.emotes.isEmpty ? null : _positions(r);
    final m = TwitchMessage(
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
      badges: look.badges.isEmpty
          ? null
          : _badges(look.badges, sets?.badgesAt(r.timestampMs)),
      sourceBroadcasterId: r.sourceBroadcasterId,
      sourceMessageId: r.sourceMessageId,
    );
    rewrite?.call(m);
    return m..emoteTokens = _tokens(r, m, defs, sets);
  }

  /// The row's emotes: the stored ones over the sets at the row's time,
  /// through the live tokenizer, or only the stored ones for a row that
  /// stored them all. Null sends the row through a parse on render.
  static List<EmoteToken>? _tokens(
    ArchiveRow r,
    TwitchMessage m,
    Map<String, Emote> defs,
    ChannelSets? sets,
  ) {
    if (r.isSystem) return null;
    final byCode = <String, Emote>{};
    for (final t in r.tokens) {
      final emote = defs[t.key];
      if (emote == null) {
        if (r.tokensStored) return null;
        continue;
      }
      byCode[emote.code] = emote;
    }
    var twitch = m.emotePositions;
    if (!r.tokensStored) {
      if (r.sourceBroadcasterId != null) return null;
      final at = sets?.emotesAt(r.timestampMs);
      if (at == null) return null;
      // Personal emotes sit under the channel's, as in the live lookup.
      byCode.addAll(at);
      if (!sets!.twitchOn) twitch = null;
    }
    return [
      for (final token in EmoteStore.tokenize(
        text: m.text,
        positions: twitch,
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

  /// Badges of [combo], drawn as [versions] held them when given; a badge
  /// they miss draws as today.
  static List<MessageBadge> _badges(
    String combo,
    Map<String, BadgeVersion>? versions,
  ) => [
    for (final part in combo.split(','))
      if (part.contains('/'))
        MessageBadge(
          setId: part.substring(0, part.indexOf('/')),
          versionId: part.substring(part.indexOf('/') + 1),
          drawn: versions?[part],
        ),
  ];
}
