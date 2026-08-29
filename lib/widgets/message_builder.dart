import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';
import '../services/link_whitelist.dart';
import '../services/third_party_badge_service.dart';
import '../services/twitch_badge_service.dart';
import '../util/log.dart';
import 'emote_text.dart';

class MessageBuilder {
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final ThirdPartyBadgeService thirdPartyBadgeService;
  final void Function(List<GenericEmote>) onShowEmoteSheet;
  final LinkWhitelist linkWhitelist;

  MessageBuilder({
    required this.emoteManager,
    required this.badgeService,
    required this.thirdPartyBadgeService,
    required this.onShowEmoteSheet,
    LinkWhitelist? linkWhitelist,
  }) : linkWhitelist = linkWhitelist ?? LinkWhitelist.instance;

  /// Composite cache key for message spans. Prime multiplier avoids collisions.
  int get _spanCacheVersion =>
      emoteManager.version * 1000003 +
      badgeService.version +
      linkWhitelist.entries.fold(0, (h, e) => h ^ e.hashCode * 31);

  List<InlineSpan> buildMessageSpans(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored = false,
    double textScale = 1.0,
  }) {
    final spanVersion = _spanCacheVersion;
    final stale =
        msg.cachedSpans == null ||
        msg.cachedSpansVersion != spanVersion ||
        msg.cachedSpansScale != textScale;
    if (stale) {
      msg.cachedSpans = _computeMessageSpans(msg, channel, scale: textScale);
      msg.cachedSpansVersion = spanVersion;
      msg.cachedSpansScale = textScale;
    }
    if (colored) {
      return [
        ...msg.cachedSpans!.map((span) {
    // Links keep blue style (repainting hides clickability).
          if (span is TextSpan && span.recognizer == null) {
            return TextSpan(
              text: span.text,
              style: TextStyle(
                fontSize: 14 * textScale,
                color: parseColor(msg.color, background: surface),
                decoration: TextDecoration.none,
              ),
              recognizer: span.recognizer,
            );
          }
          return span;
        }),
      ];
    }
    return msg.cachedSpans!;
  }

  List<InlineSpan> _computeMessageSpans(
    TwitchMessage msg,
    String channel, {
    double scale = 1.0,
  }) {
    // Shared-chat: resolve emotes against source channel's set.
    final lookupChannel = msg.sourceBroadcasterId != null
        ? badgeService.resolveChannelLogin(msg.sourceBroadcasterId!) ?? channel
        : channel;
    final channelEmotes = emoteManager.byCode(lookupChannel);
    return EmoteText.build(
      text: msg.text,
      twitchPositions: msg.emotePositions,
      channelEmotes: channelEmotes,
      onEmoteTap: onShowEmoteSheet,
      scale: scale,
      linkWhitelist: linkWhitelist.entries,
    );
  }

  List<WidgetSpan> buildBadgeSpans(
    String channel,
    TwitchMessage msg, {
    double badgeScale = 1.0,
  }) {
    // Badge cache depends on third-party data, shared-chat lookup, and scale.
    final cacheVersion =
        thirdPartyBadgeService.version * 1000003 + badgeService.version;
    final stale =
        msg.cachedBadgeSpans == null ||
        msg.cachedBadgeSpansVersion != cacheVersion ||
        msg.cachedBadgeSpansScale != badgeScale;
    if (stale) {
      return _computeBadgeSpans(channel, msg, cacheVersion, badgeScale);
    }
    return msg.cachedBadgeSpans!;
  }

  List<WidgetSpan> _computeBadgeSpans(
    String channel,
    TwitchMessage msg,
    int cacheVersion,
    double badgeScale,
  ) {
    final badgeSize = 18.0 * badgeScale;
    final spans = <WidgetSpan>[];

    if (msg.sourceBroadcasterId != null) {
      final avatarUrl = badgeService.resolveChannelAvatar(
        msg.sourceBroadcasterId!,
      );
      if (avatarUrl != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label:
                  badgeService.resolveChannelDisplayName(
                    msg.sourceBroadcasterId!,
                  ) ??
                  'shared chat',
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: ClipOval(
                  child: CachedNetworkImage(
                    imageUrl: avatarUrl,
                    width: badgeSize,
                    height: badgeSize,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, _) =>
                        SizedBox(width: badgeSize, height: badgeSize),
                    errorWidget: (_, url, error) {
                      logDebug('Shared chat badge image failed: $url - $error');
                      return SizedBox(width: badgeSize, height: badgeSize);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    final badges = msg.badges;
    if (badges != null) {
      for (final badge in badges) {
        final url = badgeService.resolveBadgeUrl(
          channel,
          badge.setId,
          badge.versionId,
        );
        if (url == null) continue;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: badge.setId,
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: CachedNetworkImage(
                  imageUrl: url,
                  width: badgeSize,
                  height: badgeSize,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) =>
                      SizedBox(width: badgeSize, height: badgeSize),
                  errorWidget: (_, url, error) {
                    logDebug('Badge image load failed: $url - $error');
                    return SizedBox(width: badgeSize, height: badgeSize);
                  },
                ),
              ),
            ),
          ),
        );
      }
    }

    if (msg.userId != null) {
      final tpBadgeUrl =
          thirdPartyBadgeService.resolveFfzBadgeUrl(msg.userId!) ??
          thirdPartyBadgeService.resolveBttvBadgeUrl(msg.userId!) ??
          thirdPartyBadgeService.resolveSevenTvBadgeUrl(msg.userId!);
      if (tpBadgeUrl != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: 'third-party badge',
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: CachedNetworkImage(
                  imageUrl: tpBadgeUrl,
                  width: badgeSize,
                  height: badgeSize,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) =>
                      SizedBox(width: badgeSize, height: badgeSize),
                  errorWidget: (_, url, error) {
                    logDebug('Third-party badge load failed: $url - $error');
                    return SizedBox(width: badgeSize, height: badgeSize);
                  },
                ),
              ),
            ),
          ),
        );
      }
    }

    msg.cachedBadgeSpansVersion = cacheVersion;
    msg.cachedBadgeSpansScale = badgeScale;
    return msg.cachedBadgeSpans = spans;
  }
}
