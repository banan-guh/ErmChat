import 'dart:math';

import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/emote_images.dart';
import '../emotes/emote_picker.dart';
import '../util/constants.dart';
import '../util/log.dart';
import '../util/chat_text.dart';
import 'emote_scale_resolver.dart';
import 'emote_effect.dart';
import '../services/link_whitelist.dart';
import 'link_whitelist.dart';
import '../emotes/emote.dart';
import '../emotes/emote_catalog.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';

class _EmoteSpanData {
  final Emote base;

  /// Modifiers drawn on top of [base].
  final List<Emote> overlays;

  /// Every attached modifier, hidden ones included, for the emote sheet.
  final List<Emote> modifiers;

  /// FFZ effect bits applied to [base].
  final int effects;

  const _EmoteSpanData({
    required this.base,
    this.overlays = const [],
    this.modifiers = const [],
    this.effects = 0,
  });

  /// [base] with [mod] attached: hidden FFZ modifiers only add their effects
  /// ([effectsOn] off drops those effects).
  _EmoteSpanData attach(Emote mod, {required bool effectsOn}) {
    final fx = ffzEffects(mod);
    final hidden = fx & FfzEffect.hidden != 0;
    return _EmoteSpanData(
      base: base,
      overlays: hidden ? overlays : [...overlays, mod],
      modifiers: [...modifiers, mod],
      effects: effectsOn ? effects | (fx & ~FfzEffect.hidden) : effects,
    );
  }
}

class EmoteText {
  static List<InlineSpan> build({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required EmoteLookup? channelEmotes,
    required EmoteImages emoteImages,
    List<EmoteToken>? resolvedTokens,
    void Function(List<Emote>)? onEmoteTap,
    double scale = 1.0,
    List<String>? linkWhitelist,
    void Function(String email)? onEmailTap,
    bool showImages = false,
    void Function(String url)? onImageTap,
    bool animateGifs = true,
    bool ffzEffects = true,
    bool bttvModifiers = true,
  }) {
    try {
      return _buildUnsafe(
        text: text,
        twitchPositions: twitchPositions,
        channelEmotes: channelEmotes,
        resolvedTokens: resolvedTokens,
        onEmoteTap: onEmoteTap,
        scale: scale,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
        showImages: showImages,
        onImageTap: onImageTap,
        animateGifs: animateGifs,
        ffzEffects: ffzEffects,
        bttvModifiers: bttvModifiers,
        emoteImages: emoteImages,
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
    required EmoteLookup? channelEmotes,
    required EmoteImages emoteImages,
    List<EmoteToken>? resolvedTokens,
    void Function(List<Emote>)? onEmoteTap,
    double scale = 1.0,
    List<String>? linkWhitelist,
    void Function(String email)? onEmailTap,
    bool showImages = false,
    void Function(String url)? onImageTap,
    bool animateGifs = true,
    bool ffzEffects = true,
    bool bttvModifiers = true,
  }) {
    if (channelEmotes == null && resolvedTokens == null) {
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

    final segments = resolvedTokens != null
        ? _segmentsFromTokens(text, resolvedTokens)
        : _buildSegments(text, twitchPositions, channelEmotes!.byCode);
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
            emoteImages: emoteImages,
          ),
        );
        currentBase = null;
        currentBaseEnd = null;
      }
      flushText();
      pendingSpace = null;
    }

    // BTTV prefix modifiers waiting for the emote they apply to, and their
    // source segments in case none follows.
    var prefix = <Emote>[];
    var prefixEffects = 0;
    var prefixSegments = <_Segment>[];
    // Unattached modifiers draw as the plain emotes they are.
    void dropPrefix() {
      for (final s in prefixSegments) {
        if (s is EmoteSegment) {
          flushBase();
          currentBase = _EmoteSpanData(base: s.emote);
          currentBaseEnd = s.endIndex;
        } else if (s is TextSegment) {
          buffer += s.text;
          pendingSpace = (pendingSpace ?? '') + s.text;
        }
      }
      prefix = [];
      prefixEffects = 0;
      prefixSegments = [];
    }

    // Zero-width emotes overlay on preceding base; whitespace between is consumed.
    for (final seg in segments) {
      if (prefix.isNotEmpty) {
        if (seg is TextSegment && seg.text.trim().isEmpty) {
          prefixSegments.add(seg);
          continue;
        }
        if (seg is EmoteSegment && bttvModifierEffects(seg.emote) == 0) {
          // z! pulls the emote against whatever came before it.
          if (prefixEffects & BttvEffect.zeroSpace != 0) {
            buffer = buffer.trimRight();
          }
          flushBase();
          currentBase = _EmoteSpanData(
            base: seg.emote,
            modifiers: prefix,
            effects: prefixEffects,
          );
          currentBaseEnd = seg.endIndex;
          prefix = [];
          prefixEffects = 0;
          prefixSegments = [];
          continue;
        }
        if (seg is! EmoteSegment) dropPrefix();
      }
      if (seg is EmoteSegment) {
        final bttvFx = bttvModifiers ? bttvModifierEffects(seg.emote) : 0;
        if (bttvFx != 0) {
          prefix = [...prefix, seg.emote];
          prefixEffects |= bttvFx;
          prefixSegments.add(seg);
          continue;
        }
      }
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
            currentBase = currentBase!.attach(seg.emote, effectsOn: ffzEffects);
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
            currentBase = currentBase!.attach(seg.emote, effectsOn: ffzEffects);
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

    if (prefix.isNotEmpty) dropPrefix();
    flushBase();

    return spans;
  }

  static List<_Segment> _buildSegments(
    String text,
    List<EmotePosition>? twitchPositions,
    Map<String, Emote> byCode,
  ) {
    return EmoteManager.tokenize(
      text: text,
      positions: twitchPositions,
      byCode: byCode,
    ).map(_segmentForToken).toList();
  }

  /// Rebuilds segments from a frozen resolution: emote tokens plus the text
  /// between them, so no lookup or tokenize runs.
  static List<_Segment> _segmentsFromTokens(
    String text,
    List<EmoteToken> tokens,
  ) {
    final segments = <_Segment>[];
    var cursor = 0;
    for (final token in tokens) {
      final start = token.start.clamp(0, text.length);
      final end = token.end.clamp(start, text.length);
      if (start > cursor) {
        segments.add(TextSegment(text: text.substring(cursor, start)));
      }
      if (token.isEmote && end > start) {
        segments.add(
          EmoteSegment(emote: token.emote!, startIndex: start, endIndex: end),
        );
      }
      cursor = end;
    }
    if (cursor < text.length) {
      segments.add(TextSegment(text: text.substring(cursor)));
    }
    return segments;
  }

  static _Segment _segmentForToken(EmoteToken token) => token.isEmote
      ? EmoteSegment(
          emote: token.emote!,
          startIndex: token.start,
          endIndex: token.end,
        )
      : TextSegment(text: token.text);

  static Size _emoteSize(Emote emote, double scale) {
    final s = min(28.0, 28.0 * emote.relativeScale) * scale;
    return Size(s * emote.aspectRatio, s);
  }

  static Widget _emoteImage(
    Emote emote,
    double width,
    double height, {
    required bool animateGifs,
    required EmoteImages emoteImages,
    double scale = 1.0,
  }) {
    // The resolver picks the best cached scale live and falls back to the code
    // as text when nothing is cached on the nothing tier.
    return EmoteScaleResolver(
      emote: emote,
      surface: EmoteSurface.chat,
      images: emoteImages,
      width: width,
      height: height,
      fit: BoxFit.contain,
      lean: true,
      animateGifs: animateGifs,
      textStyle: TextStyle(fontSize: 14 * scale),
    );
  }

  // Bounding box across overlays; center each image. Clip.none for overflow.
  static WidgetSpan _buildEmoteSpan(
    _EmoteSpanData data, {
    required EmoteImages emoteImages,
    void Function(List<Emote>)? onEmoteTap,
    double scale = 1.0,
    bool animateGifs = true,
  }) {
    final rawSize = _emoteSize(data.base, scale);
    final fx = data.effects;
    final baseSize = fx == 0
        ? rawSize
        : emoteEffectSize(fx, rawSize, rawSize.height);
    var maxW = baseSize.width;
    var maxH = baseSize.height;
    for (final overlay in data.overlays) {
      final o = _emoteSize(overlay, scale);
      if (o.width > maxW) maxW = o.width;
      if (o.height > maxH) maxH = o.height;
    }

    // Stretch effects draw the emote at its own size, filled to the box.
    final stretch = emoteEffectStretches(fx);
    final imageSize = stretch ? rawSize : baseSize;
    Widget baseImage() {
      final image = _emoteImage(
        data.base,
        imageSize.width,
        imageSize.height,
        animateGifs: animateGifs,
        emoteImages: emoteImages,
        scale: scale,
      );
      if (!stretch) return image;
      return SizedBox(
        width: baseSize.width,
        height: baseSize.height,
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: imageSize.width,
            height: imageSize.height,
            child: image,
          ),
        ),
      );
    }

    Widget? effected;
    if (fx != 0) {
      // Slide scrolls a strip of two copies through the emote's box.
      final image = fx & FfzEffect.slide != 0
          ? OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: baseSize.width * 2,
              maxWidth: baseSize.width * 2,
              child: Row(children: [baseImage(), baseImage()]),
            )
          : baseImage();
      effected = SizedBox(
        width: baseSize.width,
        height: baseSize.height,
        child: EmoteEffectBox(
          effects: fx,
          unit: rawSize.height / 28,
          child: RepaintBoundary(child: image),
        ),
      );
    }

    final children = <Widget>[
      Positioned(
        left: (maxW - baseSize.width) / 2,
        top: (maxH - baseSize.height) / 2,
        child: effected ?? baseImage(),
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
            emoteImages: emoteImages,
            scale: scale,
          ),
        ),
      );
    }
    // No per-emote Semantics: tile already wraps with excludeSemantics.
    Widget emoteWidget;
    if (data.overlays.isEmpty) {
      // Unconstrained resolver: images and placeholders size to the emote
      // box, but the text fallback (nothing cached at the nothing tier)
      // flows as normal inline text instead of wrapping inside that box.
      emoteWidget = effected ?? baseImage();
    } else {
      emoteWidget = SizedBox(
        width: maxW,
        height: maxH,
        child: Stack(clipBehavior: Clip.none, children: children),
      );
    }
    if (onEmoteTap != null) {
      emoteWidget = GestureDetector(
        onTap: () => onEmoteTap([data.base, ...data.modifiers]),
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
  final Emote emote;
  final int startIndex;
  final int endIndex;

  const EmoteSegment({
    required this.emote,
    required this.startIndex,
    required this.endIndex,
  });
}

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
    final collapsed = cleanChatText(text);
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
  final collapsed = cleanChatText(text);
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
                      child: Builder(
                        builder: (context) => Icon(
                          Icons.image_outlined,
                          size: 20.0 * scale,
                          color: Colors.blue,
                          semanticLabel: context.l10n.expandImage,
                        ),
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
