import '../emotes/emote.dart';

/// Provider emote lists produced by one global fetch, plus the providers that
/// failed and the account Twitch catalogue unlock ids. A provider with an
/// empty list is omitted so a commit keeps the retained list.
class GlobalEmoteFetch {
  const GlobalEmoteFetch({
    this.byProvider = const {},
    this.failed = const {},
    this.twitchCatalogUnlockIds = const {},
  });

  final Map<EmoteType, List<Emote>> byProvider;
  final Set<EmoteType> failed;

  /// Ids from the global unlockable Twitch catalogue (broadcaster_id=0). The
  /// global commit applies them to store state; the fetch stays pure.
  final Set<String> twitchCatalogUnlockIds;
}

/// Provider emote lists produced by one channel fetch, plus the 7TV identity
/// and the providers that failed. A provider with an empty list is omitted so
/// a commit keeps the retained list.
class ChannelEmoteFetch {
  const ChannelEmoteFetch({
    this.byProvider = const {},
    this.failed = const {},
    this.sevenTvSetId,
    this.sevenTvUserId,
  });

  final Map<EmoteType, List<Emote>> byProvider;
  final Set<EmoteType> failed;
  final String? sevenTvSetId;
  final String? sevenTvUserId;
}
