import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../models/generic_emote.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';
import '../util/constants.dart';
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

  /// Whether Giphy attachments render inline. Off falls back to plain text.
  bool showGifs;

  /// Inline Giphy box height at textScale 1.0; width derives from 3:2 aspect.
  double gifHeight;

  /// Whether image links get an expand icon. Previews render outside the
  /// cached spans (tile column), so only the icon joins the cache key.
  bool showImages;

  /// Whether animated Twitch emotes play. Off renders them frozen through
  /// the custom pipeline; on renders them via the stock image provider.
  /// Joins the cache key so flips recompute spans lazily.
  bool animateGifs;

  /// Inline image preview max height at textScale 1.0.
  double imageHeight;

  /// Tap handler for email spans (copy + feedback). Null copies silently.
  void Function(String email)? onEmailTap;

  MessageBuilder({
    required this.emoteManager,
    required this.badgeService,
    required this.thirdPartyBadgeService,
    required this.onShowEmoteSheet,
    LinkWhitelist? linkWhitelist,
    this.showGifs = kGiphyInlineEnabledDefault,
    this.gifHeight = kGiphyInlineHeightDefault,
    this.showImages = kImageEmbedEnabledDefault,
    this.imageHeight = kImageEmbedHeightDefault,
    this.animateGifs = true,
  }) : linkWhitelist = linkWhitelist ?? LinkWhitelist.instance;

  // Render memos live here, not on the messages: the buffer stays plain data,
  // and a message dropping out of the buffer releases its spans with it.
  final _bodyCache = Expando<_BodySpans>();
  final _badgeCache = Expando<_BadgeSpans>();

  /// Composite cache key for message spans. Prime multiplier avoids collisions.
  /// Giphy prefs join the key (prime offset for the toggle, spread factor
  /// for the height) so changes recompute spans lazily.
  int get _spanCacheVersion {
    var v = emoteManager.version * 1000003 + badgeService.version;
    v += linkWhitelist.entries.fold<int>(0, (h, e) => h ^ e.hashCode * 31);
    if (linkWhitelist.enabled) v += 30000031;
    if (onEmailTap != null) v += 40000037;
    if (showGifs) v += 10000019 + (gifHeight * 13).toInt();
    if (showImages) v += 20000029;
    if (!animateGifs) v += 50000051;
    return v;
  }

  List<InlineSpan> buildMessageSpans(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored = false,
    double textScale = 1.0,
    void Function(String url)? onImageTap,
  }) {
    // Tile-bound image callbacks must not ride the shared cache: panels reuse
    // message objects, and a cached closure would toggle the wrong tile.
    if (onImageTap != null) {
      final fresh = _computeMessageSpans(
        msg,
        channel,
        scale: textScale,
        onImageTap: onImageTap,
      );
      if (colored) return _recolor(fresh, msg, surface, textScale);
      return fresh;
    }
    final spanVersion = _spanCacheVersion;
    final cached = _bodyCache[msg];
    final stale =
        cached == null ||
        cached.version != spanVersion ||
        cached.scale != textScale;
    if (!stale) {
      return colored
          ? _recolor(cached.spans, msg, surface, textScale)
          : cached.spans;
    }
    if (cached != null) _disposeSpanRecognizers(cached.spans);
    final fresh = _computeMessageSpans(msg, channel, scale: textScale);
    // Link and email spans own TapGestureRecognizers that have no dispose
    // hook on message eviction, so never cache them. Link-heavy messages
    // rebuild per tile instead of leaking recognizers per message.
    if (!_containsRecognizer(fresh)) {
      _bodyCache[msg] = _BodySpans(fresh, spanVersion, textScale);
    }
    if (colored) return _recolor(fresh, msg, surface, textScale);
    return fresh;
  }

  /// Whether [spans] is the shared cached body list for [msg], so the tile
  /// knows not to own (and dispose) it.
  bool bodyIsCached(TwitchMessage msg, List<InlineSpan> spans) {
    final cached = _bodyCache[msg];
    return cached != null && identical(cached.spans, spans);
  }

  bool _containsRecognizer(List<InlineSpan> spans) {
    for (final span in spans) {
      if (span is TextSpan) {
        if (span.recognizer != null) return true;
        if (span.children != null && _containsRecognizer(span.children!)) {
          return true;
        }
      }
    }
    return false;
  }

  void _disposeSpanRecognizers(List<InlineSpan>? spans) {
    if (spans == null) return;
    for (final span in spans) {
      if (span is TextSpan) {
        span.recognizer?.dispose();
        if (span.children != null) _disposeSpanRecognizers(span.children!);
      }
    }
  }

  List<InlineSpan> _recolor(
    List<InlineSpan> spans,
    TwitchMessage msg,
    Color surface,
    double textScale,
  ) {
    return [
      ...spans.map((span) {
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

  List<InlineSpan> _computeMessageSpans(
    TwitchMessage msg,
    String channel, {
    double scale = 1.0,
    void Function(String url)? onImageTap,
  }) {
    // Shared-chat: resolve emotes against source channel's set.
    final lookupChannel = msg.sourceBroadcasterId != null
        ? badgeService.resolveChannelLogin(msg.sourceBroadcasterId!) ?? channel
        : channel;
    final channelEmotes = emoteManager.byCodeForSender(
      lookupChannel,
      msg.userId,
    );
    // Giphy toggle off falls back to plain text (same as no attachments).
    final gifs = showGifs ? msg.gifAttachments : null;
    if (gifs == null || gifs.isEmpty) {
      return EmoteText.build(
        text: msg.text,
        twitchPositions: msg.emotePositions,
        channelEmotes: channelEmotes,
        onEmoteTap: onShowEmoteSheet,
        scale: scale,
        linkWhitelist: linkWhitelist.entries,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        animateGifs: animateGifs,
      );
    }
    // GIF messages: splice inline GIF images over their text ranges; GIF wins
    // over emotes/text in its range, gaps render through the normal path.
    final sorted = [...gifs]
      ..sort((a, b) => a.startIndex.compareTo(b.startIndex));
    final spans = <InlineSpan>[];
    var cursor = 0;

    void addGap(String gap, int gapStart) {
      if (gap.isEmpty) return;
      final inner = <EmotePosition>[];
      for (final p in msg.emotePositions ?? const <EmotePosition>[]) {
        if (p.startIndex >= gapStart && p.endIndex <= gapStart + gap.length) {
          inner.add(
            EmotePosition(
              emoteId: p.emoteId,
              startIndex: p.startIndex - gapStart,
              endIndex: p.endIndex - gapStart,
              emoteCode: p.emoteCode,
            ),
          );
        }
      }
      spans.addAll(
        EmoteText.build(
          text: gap,
          twitchPositions: inner.isEmpty ? null : inner,
          channelEmotes: channelEmotes,
          onEmoteTap: onShowEmoteSheet,
          scale: scale,
          linkWhitelist: linkWhitelist.entries,
          onEmailTap: onEmailTap,
          showImages: showImages,
          onImageTap: onImageTap,
          animateGifs: animateGifs,
        ),
      );
    }

    for (final gif in sorted) {
      if (gif.startIndex < cursor) continue;
      if (gif.startIndex > msg.text.length || gif.endIndex > msg.text.length) {
        continue;
      }
      addGap(msg.text.substring(cursor, gif.startIndex), cursor);
      spans.add(_buildGifSpan(gif.url, scale));
      cursor = gif.endIndex;
    }
    addGap(msg.text.substring(cursor), cursor);
    return spans;
  }

  /// Inline chat GIF. Fixed box with contain fit. Memory-only stock provider
  /// ([NetworkImage], no disk): Giphy GIFs are sparse one-offs, so they must
  /// not consume emote disk slots or init disk I/O during span build.
  /// Always animates (ignores the animate_gifs freeze, same as before) and
  /// shares one engine decode per URL within the session.
  WidgetSpan _buildGifSpan(String url, double scale) {
    final height = gifHeight * scale;
    final width = gifHeight * 1.5 * scale;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Image(
          key: ValueKey(url),
          image: NetworkImage(url),
          width: width,
          height: height,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // Same static gray as every other placeholder app-wide.
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : Container(
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    color: kEmotePlaceholderGray,
                    borderRadius: BorderRadius.circular(
                      kEmotePlaceholderRadius,
                    ),
                  ),
                ),
          errorBuilder: (_, _, _) => SizedBox(width: width, height: height),
        ),
      ),
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
    final cached = _badgeCache[msg];
    final stale =
        cached == null ||
        cached.version != cacheVersion ||
        cached.scale != badgeScale;
    if (!stale) return cached.spans;
    final spans = _computeBadgeSpans(channel, msg, badgeScale);
    _badgeCache[msg] = _BadgeSpans(spans, cacheVersion, badgeScale);
    return spans;
  }

  /// Channel-active badges for one message, newest resolution wins. Shared
  /// chat avatar first, Twitch sets in tag order (unresolvable skipped),
  /// then one third-party badge.
  List<CardBadge> resolveCardBadges(String channel, TwitchMessage msg) {
    final out = <CardBadge>[];
    if (msg.sourceBroadcasterId != null) {
      final avatarUrl = badgeService.resolveChannelAvatar(
        msg.sourceBroadcasterId!,
      );
      if (avatarUrl != null) {
        out.add(
          CardBadge(
            url: avatarUrl,
            label:
                badgeService.resolveChannelDisplayName(
                  msg.sourceBroadcasterId!,
                ) ??
                'shared chat',
            circular: true,
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
        out.add(CardBadge(url: url, label: badge.setId));
      }
    }
    if (msg.userId != null) {
      final tpBadgeUrl =
          thirdPartyBadgeService.resolveFfzBadgeUrl(msg.userId!) ??
          thirdPartyBadgeService.resolveBttvBadgeUrl(msg.userId!) ??
          thirdPartyBadgeService.resolveSevenTvBadgeUrl(msg.userId!);
      if (tpBadgeUrl != null) {
        out.add(CardBadge(url: tpBadgeUrl, label: 'third-party badge'));
      }
    }
    return out;
  }

  List<WidgetSpan> _computeBadgeSpans(
    String channel,
    TwitchMessage msg,
    double badgeScale,
  ) {
    final badgeSize = 18.0 * badgeScale;
    final spans = <WidgetSpan>[];
    for (final badge in resolveCardBadges(channel, msg)) {
      final image = CachedNetworkImage(
        imageUrl: badge.url,
        width: badgeSize,
        height: badgeSize,
        fit: badge.circular ? BoxFit.cover : BoxFit.contain,
        fadeInDuration: Duration.zero,
        placeholder: (_, _) => SizedBox(width: badgeSize, height: badgeSize),
        errorWidget: (_, url, error) {
          logDebug('Badge image load failed: $url - $error');
          return SizedBox(width: badgeSize, height: badgeSize);
        },
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Semantics(
            label: badge.label,
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: badge.circular ? ClipOval(child: image) : image,
            ),
          ),
        ),
      );
    }

    return spans;
  }
}

class _BodySpans {
  _BodySpans(this.spans, this.version, this.scale);

  final List<InlineSpan> spans;
  final int version;
  final double scale;
}

class _BadgeSpans {
  _BadgeSpans(this.spans, this.version, this.scale);

  final List<WidgetSpan> spans;
  final int version;
  final double scale;
}
