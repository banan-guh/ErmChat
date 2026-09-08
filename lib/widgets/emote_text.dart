import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/emote_cache_manager.dart';
import '../util/constants.dart';
import 'emote_image_provider.dart';
import '../util/log.dart';
import 'inline_emote_view.dart';
import '../services/link_whitelist.dart';
import 'link_whitelist.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';

class _EmoteSpanData {
  final GenericEmote base;
  final List<GenericEmote> overlays;

  const _EmoteSpanData({required this.base, this.overlays = const []});
}

class EmoteText {
  static List<InlineSpan> build({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required ChannelEmotes? channelEmotes,
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
    List<String>? linkWhitelist,
    void Function(String email)? onEmailTap,
    bool showImages = false,
    void Function(String url)? onImageTap,
    bool animateGifs = true,
  }) {
    try {
      return _buildUnsafe(
        text: text,
        twitchPositions: twitchPositions,
        channelEmotes: channelEmotes,
        onEmoteTap: onEmoteTap,
        scale: scale,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        animateGifs: animateGifs,
      );
    } catch (e, stack) {
      logDebug('[EmoteText.build] error: $e');
      logDebug('[EmoteText.build] text="$text"');
      logDebug('[EmoteText.build] stack=$stack');
      return parseTextWithLinks(
        text,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        scale: scale,
      );
    }
  }

  static List<InlineSpan> _buildUnsafe({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required ChannelEmotes? channelEmotes,
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
    List<String>? linkWhitelist,
    void Function(String email)? onEmailTap,
    bool showImages = false,
    void Function(String url)? onImageTap,
    bool animateGifs = true,
  }) {
    if (channelEmotes == null) {
      return parseTextWithLinks(
        text,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        scale: scale,
      );
    }

    final spans = <InlineSpan>[];
    final byCode = channelEmotes.byCode;

    final segments = _buildSegments(text, twitchPositions, byCode);
    if (segments.isEmpty) {
      return parseTextWithLinks(
        text,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        scale: scale,
      );
    }

    _EmoteSpanData? currentBase;
    int? currentBaseEnd;
    String? pendingSpace;
    // Buffer text runs for unified linkification (fractured links survive whitespace).
    var buffer = '';

    void flushText() {
      if (buffer.isNotEmpty) {
        spans.addAll(
          parseTextWithLinks(
            buffer,
            linkWhitelist: linkWhitelist,
            onEmailTap: onEmailTap,
            showImages: showImages,
            onImageTap: onImageTap,
            scale: scale,
          ),
        );
        buffer = '';
      }
    }

    void flushBase() {
      // Emit emote before trailing text to preserve source order.
      if (currentBase != null) {
        spans.add(
          _buildEmoteSpan(
            currentBase!,
            onEmoteTap: onEmoteTap,
            scale: scale,
            animateGifs: animateGifs,
          ),
        );
        currentBase = null;
        currentBaseEnd = null;
      }
      flushText();
      pendingSpace = null;
    }

    // Zero-width emotes overlay on preceding base; whitespace between is consumed.
    for (final seg in segments) {
      if (seg is TextSegment) {
        if (seg.text.trim().isEmpty) {
          buffer += seg.text;
          pendingSpace = (pendingSpace ?? '') + seg.text;
        } else {
          // Don't flush: text runs must stay buffered until emote boundary for linkification.
          buffer += seg.text;
        }
      } else if (seg is EmoteSegment) {
        if (seg.emote.isZeroWidth) {
          if (currentBase != null && currentBaseEnd == seg.startIndex) {
            pendingSpace = null;
            currentBase = _EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else if (currentBase != null &&
              pendingSpace != null &&
              currentBaseEnd == seg.startIndex - pendingSpace!.length) {
            // Consume separating whitespace so it isn't rendered between composited emotes.
            if (buffer.endsWith(pendingSpace!)) {
              buffer = buffer.substring(
                0,
                buffer.length - pendingSpace!.length,
              );
            }
            pendingSpace = null;
            currentBase = _EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else {
            flushBase();
            currentBase = _EmoteSpanData(base: seg.emote);
            currentBaseEnd = seg.endIndex;
          }
        } else {
          flushBase();
          currentBase = _EmoteSpanData(base: seg.emote);
          currentBaseEnd = seg.endIndex;
        }
      }
    }

    flushBase();

    return spans;
  }

  static List<_Segment> _buildSegments(
    String text,
    List<EmotePosition>? twitchPositions,
    Map<String, GenericEmote> byCode,
  ) {
    return EmoteManager.tokenize(
      text: text,
      positions: twitchPositions,
      byCode: byCode,
    ).map((token) {
      if (token.isEmote) {
        return EmoteSegment(
          emote: token.emote!,
          startIndex: token.start,
          endIndex: token.end,
        );
      }
      return TextSegment(text: token.text);
    }).toList();
  }

  static Size _emoteSize(GenericEmote emote, double scale) {
    final s = min(28.0, 28.0 * emote.relativeScale) * scale;
    return Size(s * emote.aspectRatio, s);
  }

  static Widget _emoteImage(
    GenericEmote emote,
    double width,
    double height, {
    required bool animateGifs,
  }) {
    // Engine-routable emotes (statics, playing Twitch GIFs) use the stock
    // provider: one shared decode per URL, no per-copy fan-out. See
    // [emoteUsesCustomLoop] for the single routing rule.
    if (!emoteUsesCustomLoop(emote, animateGifs: animateGifs)) {
      return Image(
        key: ValueKey(emote.url),
        image: CachedNetworkImageProvider(
          emote.url,
          cacheManager: EmoteCacheManager(),
        ),
        width: width,
        height: height,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        // Static shared-gray box while bytes load: no clock, no per-tick
        // repaints. Same look as every other placeholder app-wide.
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: kEmotePlaceholderGray,
                  borderRadius: BorderRadius.circular(kEmotePlaceholderRadius),
                ),
              ),
        errorBuilder: (_, _, _) => SizedBox(width: width, height: height),
      );
    }
    // Lean renderer: one render box, shared completer. Lower per-copy cost than EmoteImage.
    return InlineEmoteView(url: emote.url, width: width, height: height);
  }

  // Bounding box across overlays; center each image. Clip.none for overflow.
  static WidgetSpan _buildEmoteSpan(
    _EmoteSpanData data, {
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
    bool animateGifs = true,
  }) {
    final baseSize = _emoteSize(data.base, scale);
    var maxW = baseSize.width;
    var maxH = baseSize.height;
    for (final overlay in data.overlays) {
      final o = _emoteSize(overlay, scale);
      if (o.width > maxW) maxW = o.width;
      if (o.height > maxH) maxH = o.height;
    }

    final children = <Widget>[
      Positioned(
        left: (maxW - baseSize.width) / 2,
        top: (maxH - baseSize.height) / 2,
        child: _emoteImage(
          data.base,
          baseSize.width,
          baseSize.height,
          animateGifs: animateGifs,
        ),
      ),
    ];
    for (final overlay in data.overlays) {
      final o = _emoteSize(overlay, scale);
      children.add(
        Positioned(
          left: (maxW - o.width) / 2,
          top: (maxH - o.height) / 2,
          width: o.width,
          height: o.height,
          child: _emoteImage(
            overlay,
            o.width,
            o.height,
            animateGifs: animateGifs,
          ),
        ),
      );
    }
    // No per-emote Semantics: tile already wraps with excludeSemantics.
    Widget emoteWidget;
    if (data.overlays.isEmpty) {
      emoteWidget = SizedBox(
        width: baseSize.width,
        height: baseSize.height,
        child: _emoteImage(
          data.base,
          baseSize.width,
          baseSize.height,
          animateGifs: animateGifs,
        ),
      );
    } else {
      emoteWidget = SizedBox(
        width: maxW,
        height: maxH,
        child: Stack(clipBehavior: Clip.none, children: children),
      );
    }
    if (onEmoteTap != null) {
      emoteWidget = GestureDetector(
        onTap: () => onEmoteTap([data.base, ...data.overlays]),
        child: emoteWidget,
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: emoteWidget,
      ),
    );
  }
}

abstract class _Segment {}

class TextSegment implements _Segment {
  final String text;

  const TextSegment({required this.text});
}

class EmoteSegment implements _Segment {
  final GenericEmote emote;
  final int startIndex;
  final int endIndex;

  const EmoteSegment({
    required this.emote,
    required this.startIndex,
    required this.endIndex,
  });
}

final _collapseSpace = RegExp(r' {2,}');

/// Same linkifier stack as [parseTextWithLinks].
List<LinkifyElement> _linkifyChat(
  String collapsed,
  List<String>? linkWhitelist,
) {
  return linkify(
    collapsed,
    // looseUrl handles bare domains; show originText so the
    // scheme stays visible and highlighted.
    options: const LinkifyOptions(
      humanize: true,
      looseUrl: true,
      defaultToHttps: true,
    ),
    linkifiers: [
      // Email first: it needs the text whole, and stock UrlLinkifier
      // would eat the host half of foo@gmail.com.
      const SafeEmailLinkifier(),
      // Exact single-char domains before fuzzy fracture matching.
      const SingleCharDomainLinkifier(),
      // Bare whitelisted domains always link; fractured ones need the toggle.
      WhitelistLinkifier(
        linkWhitelist ?? const [],
        fractures: LinkWhitelist.instance.enabled,
      ),
      const UrlLinkifier(),
      // Drops loose matches with empty labels.
      const LooseUrlGuardLinkifier(),
    ],
  );
}

/// Normalized URLs in [text] that look like raw image serves, in order and
/// deduped, capped like the inline icons. Tile previews use this, so pass the
/// same whitelist entries the span path uses or fractured links disagree.
List<String> collectImageEmbedUrls(String text, {List<String>? linkWhitelist}) {
  if (!text.contains('.')) return const [];
  try {
    final collapsed = text.replaceAll(_collapseSpace, ' ');
    if (!collapsed.contains('.')) return const [];
    final urls = <String>[];
    for (final element in _linkifyChat(collapsed, linkWhitelist)) {
      if (urls.length >= kMaxImageEmbedsPerMessage) break;
      if (element is UrlElement && isImageEmbedCandidate(element.url)) {
        if (!urls.contains(element.url)) urls.add(element.url);
      }
    }
    return urls;
  } catch (e) {
    logDebug('[collectImageEmbedUrls] error: $e');
    return const [];
  }
}

List<InlineSpan> parseTextWithLinks(
  String text, {
  List<String>? linkWhitelist,
  // Tap handler for emails (copy + feedback). Null copies silently.
  void Function(String email)? onEmailTap,
  // Image embeds: candidate links get an expand icon. Null tap = no icon.
  bool showImages = false,
  void Function(String url)? onImageTap,
  double scale = 1.0,
}) {
  // Fast path: no dots and no runs means no links and nothing to collapse.
  if (!text.contains('.') && !text.contains('  ')) {
    return [TextSpan(text: text)];
  }
  final collapsed = text.replaceAll(_collapseSpace, ' ');
  // Quick guard: ~99% of chat text has no URLs.
  if (!collapsed.contains('.')) return [TextSpan(text: collapsed)];
  try {
    final spans = <InlineSpan>[];
    var imageCount = 0;
    for (final element in _linkifyChat(collapsed, linkWhitelist)) {
      if (element is UrlElement) {
        spans.add(
          TextSpan(
            text: element.originText,
            style: const TextStyle(color: Colors.blue),
            recognizer: TapGestureRecognizer()
              ..onTap = () => launchUrl(Uri.parse(element.url)),
          ),
        );
        if (showImages &&
            onImageTap != null &&
            imageCount < kMaxImageEmbedsPerMessage &&
            isImageEmbedCandidate(element.url)) {
          imageCount++;
          final url = element.url;
          // Emote-sized tap box so the toggle is as easy to hit as an emote.
          final box = 28.0 * scale;
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onImageTap(url),
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: SizedBox(
                    width: box,
                    height: box,
                    child: Center(
                      child: Icon(
                        Icons.image_outlined,
                        size: 20.0 * scale,
                        color: Colors.blue,
                        semanticLabel: 'Expand image',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
      } else if (element is EmailElement) {
        spans.add(
          TextSpan(
            text: element.emailAddress,
            style: const TextStyle(color: Colors.blue),
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                final email = element.emailAddress;
                if (onEmailTap != null) {
                  onEmailTap(email);
                } else {
                  Clipboard.setData(ClipboardData(text: email));
                }
              },
          ),
        );
      } else {
        spans.add(TextSpan(text: element.text));
      }
    }
    return spans;
  } catch (e, stack) {
    logDebug('[parseTextWithLinks] error: $e');
    logDebug('[parseTextWithLinks] text="$collapsed"');
    logDebug('[parseTextWithLinks] stack=$stack');
    return [TextSpan(text: collapsed)];
  }
}
