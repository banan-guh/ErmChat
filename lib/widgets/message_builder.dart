import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';
import '../services/twitch_badge_service.dart';
import '../util/log.dart';
import 'emote_text.dart';

class MessageBuilder {
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final void Function(List<GenericEmote>) onShowEmoteSheet;

  MessageBuilder({
    required this.emoteManager,
    required this.badgeService,
    required this.onShowEmoteSheet,
  });

  List<InlineSpan> buildMessageSpans(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored = false,
    double textScale = 1.0,
  }) {
    final emoteVersion = emoteManager.version;
    if (msg.cachedSpans == null || msg.cachedSpansVersion != emoteVersion) {
      msg.cachedSpans = _computeMessageSpans(msg, channel, scale: textScale);
      msg.cachedSpansVersion = emoteVersion;
    }
    if (colored) {
      return [
        ...msg.cachedSpans!.map((span) {
          if (span is TextSpan) {
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
    final channelEmotes = emoteManager.byCode(channel);
    return EmoteText.build(
      text: msg.text,
      twitchPositions: msg.emotePositions,
      channelEmotes: channelEmotes,
      onEmoteTap: onShowEmoteSheet,
      scale: scale,
    );
  }

  List<WidgetSpan> buildBadgeSpans(
    String channel,
    TwitchMessage msg, {
    double badgeScale = 1.0,
  }) {
    if (msg.cachedBadgeSpans != null) return msg.cachedBadgeSpans!;
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
              label: msg.sourceBroadcasterName ?? 'shared chat',
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
    return msg.cachedBadgeSpans = spans;
  }
}
