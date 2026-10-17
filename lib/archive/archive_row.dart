/// An edit the archive applies to a row already sealed into a block:
/// `remove` drops the row, `deleted` sets its deleted flag.
enum ArchiveEdit { remove, deleted }

/// A Twitch emote occurrence: id plus position in the message text.
/// The emote code is derivable from the text, so it is not stored.
class ArchiveEmote {
  const ArchiveEmote(this.id, this.start, this.end);

  final String id;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is ArchiveEmote &&
      other.id == id &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(id, start, end);
}

/// A 7TV, BTTV or FFZ emote occurrence: the key of its stored definition
/// (provider, id and code, so a renamed alias stays its own version) plus
/// its position in the message text.
class ArchiveToken {
  const ArchiveToken(this.key, this.start, this.end);

  final String key;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is ArchiveToken &&
      other.key == key &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(key, start, end);
}

/// One archived message. Name, color and badges live in the user tables and
/// are reached through [user], an id from `UserTables.internState`.
class ArchiveRow {
  const ArchiveRow({
    required this.timestampMs,
    required this.text,
    this.user = 0,
    this.isSystem = false,
    this.isAction = false,
    this.isBanNotice = false,
    this.deleted = false,
    this.isFirstMessage = false,
    this.isBackfill = false,
    this.isHistory = false,
    this.messageId,
    this.replyParentId,
    this.threadRootId,
    this.replyToUser,
    this.msgId,
    this.customRewardId,
    this.bitsAmount,
    this.pinnedPaidAmount,
    this.sourceBroadcasterId,
    this.sourceMessageId,
    this.emotes = const [],
    this.tokens = const [],
    this.tokensStored = false,
    this.extraTags = const [],
  });

  final int timestampMs;
  final String text;
  final int user;
  final bool isSystem;
  final bool isAction;
  final bool isBanNotice;
  final bool deleted;
  final bool isFirstMessage;
  final bool isBackfill;
  final bool isHistory;

  /// A UUID string is stored as 16 raw bytes, anything else as text.
  final String? messageId;

  /// Parent and root ids that name another row of the block cost one varint.
  final String? replyParentId;
  final String? threadRootId;
  final String? replyToUser;
  final String? msgId;
  final String? customRewardId;
  final int? bitsAmount;
  final String? pinnedPaidAmount;
  final String? sourceBroadcasterId;
  final String? sourceMessageId;
  final List<ArchiveEmote> emotes;

  /// Third-party emotes as parsed when the message arrived. Only meaningful
  /// when [tokensStored]; otherwise the row was parsed before its catalogs
  /// landed (or never), and a read parses it against today's catalogs.
  final List<ArchiveToken> tokens;
  final bool tokensStored;

  /// Tags no field above covers, kept so unknown data is never lost.
  final List<(String, String)> extraTags;

  /// This row with its deleted flag set. Used when the archive bakes a
  /// pending edit into a sealed block.
  ArchiveRow asDeleted() => ArchiveRow(
    timestampMs: timestampMs,
    text: text,
    user: user,
    isSystem: isSystem,
    isAction: isAction,
    isBanNotice: isBanNotice,
    deleted: true,
    isFirstMessage: isFirstMessage,
    isBackfill: isBackfill,
    isHistory: isHistory,
    messageId: messageId,
    replyParentId: replyParentId,
    threadRootId: threadRootId,
    replyToUser: replyToUser,
    msgId: msgId,
    customRewardId: customRewardId,
    bitsAmount: bitsAmount,
    pinnedPaidAmount: pinnedPaidAmount,
    sourceBroadcasterId: sourceBroadcasterId,
    sourceMessageId: sourceMessageId,
    emotes: emotes,
    tokens: tokens,
    tokensStored: tokensStored,
    extraTags: extraTags,
  );

  /// This row with its message id dropped unless [keep], and its shared-chat
  /// source id dropped. Reply references stay so replies still find kept
  /// parents.
  ArchiveRow withoutIds({required bool keep}) => ArchiveRow(
    timestampMs: timestampMs,
    text: text,
    user: user,
    isSystem: isSystem,
    isAction: isAction,
    isBanNotice: isBanNotice,
    deleted: deleted,
    isFirstMessage: isFirstMessage,
    isBackfill: isBackfill,
    isHistory: isHistory,
    messageId: keep ? messageId : null,
    replyParentId: replyParentId,
    threadRootId: threadRootId,
    replyToUser: replyToUser,
    msgId: msgId,
    customRewardId: customRewardId,
    bitsAmount: bitsAmount,
    pinnedPaidAmount: pinnedPaidAmount,
    sourceBroadcasterId: sourceBroadcasterId,
    emotes: emotes,
    tokens: tokens,
    tokensStored: tokensStored,
    extraTags: extraTags,
  );

  @override
  bool operator ==(Object other) =>
      other is ArchiveRow &&
      other.timestampMs == timestampMs &&
      other.text == text &&
      other.user == user &&
      other.isSystem == isSystem &&
      other.isAction == isAction &&
      other.isBanNotice == isBanNotice &&
      other.deleted == deleted &&
      other.isFirstMessage == isFirstMessage &&
      other.isBackfill == isBackfill &&
      other.isHistory == isHistory &&
      other.messageId == messageId &&
      other.replyParentId == replyParentId &&
      other.threadRootId == threadRootId &&
      other.replyToUser == replyToUser &&
      other.msgId == msgId &&
      other.customRewardId == customRewardId &&
      other.bitsAmount == bitsAmount &&
      other.pinnedPaidAmount == pinnedPaidAmount &&
      other.sourceBroadcasterId == sourceBroadcasterId &&
      other.sourceMessageId == sourceMessageId &&
      _listEq(other.emotes, emotes) &&
      other.tokensStored == tokensStored &&
      _listEq(other.tokens, tokens) &&
      _listEq(other.extraTags, extraTags);

  @override
  int get hashCode => Object.hash(
    timestampMs,
    text,
    user,
    messageId,
    replyParentId,
    threadRootId,
    msgId,
    emotes.length,
    extraTags.length,
  );

  @override
  String toString() => 'ArchiveRow($timestampMs, $messageId, "$text")';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
