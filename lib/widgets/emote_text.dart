import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';
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
      );
    } catch (e, stack) {
      logDebug('[EmoteText.build] error: $e');
      logDebug('[EmoteText.build] text="$text"');
      logDebug('[EmoteText.build] stack=$stack');
      return parseTextWithLinks(
        text,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
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
  }) {
    if (channelEmotes == null) {
      return parseTextWithLinks(
        text,
        linkWhitelist: linkWhitelist,
        onEmailTap: onEmailTap,
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
          ),
        );
        buffer = '';
      }
    }

    void flushBase() {
      // Emit emote before trailing text to preserve source order.
      if (currentBase != null) {
        spans.add(
          _buildEmoteSpan(currentBase!, onEmoteTap: onEmoteTap, scale: scale),
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
    String url,
    double width,
    double height, {
    List<String>? alternateUrls,
  }) {
    // Lean renderer: one render box, shared completer. Lower per-copy cost than EmoteImage.
    return InlineEmoteView(
      url: url,
      width: width,
      height: height,
      alternateUrls: alternateUrls,
    );
  }

  // Bounding box across overlays; center each image. Clip.none for overflow.
  static WidgetSpan _buildEmoteSpan(
    _EmoteSpanData data, {
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
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
          data.base.url,
          baseSize.width,
          baseSize.height,
          alternateUrls: [if (data.base.url1x != null) data.base.url1x!],
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
            overlay.url,
            o.width,
            o.height,
            alternateUrls: [if (overlay.url1x != null) overlay.url1x!],
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
          data.base.url,
          baseSize.width,
          baseSize.height,
          alternateUrls: [if (data.base.url1x != null) data.base.url1x!],
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

List<InlineSpan> parseTextWithLinks(
  String text, {
  List<String>? linkWhitelist,
  // Tap handler for emails (copy + feedback). Null copies silently.
  void Function(String email)? onEmailTap,
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
    for (final element in linkify(
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
      ],
    )) {
      if (element is UrlElement) {
        spans.add(
          TextSpan(
            text: element.originText,
            style: const TextStyle(color: Colors.blue),
            recognizer: TapGestureRecognizer()
              ..onTap = () => launchUrl(Uri.parse(element.url)),
          ),
        );
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
