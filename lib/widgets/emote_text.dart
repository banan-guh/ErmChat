import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';

class EmoteSpanData {
  final GenericEmote base;
  final List<GenericEmote> overlays;

  const EmoteSpanData({required this.base, this.overlays = const []});
}

class EmoteText {
  static List<InlineSpan> build({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required ChannelEmotes? channelEmotes,
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
  }) {
    try {
      return _buildUnsafe(
        text: text,
        twitchPositions: twitchPositions,
        channelEmotes: channelEmotes,
        onEmoteTap: onEmoteTap,
        scale: scale,
      );
    } catch (e, stack) {
      debugPrint('[EmoteText.build] error: $e');
      debugPrint('[EmoteText.build] text="$text"');
      debugPrint('[EmoteText.build] stack=$stack');
      return parseTextWithLinks(text);
    }
  }

  static List<InlineSpan> _buildUnsafe({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required ChannelEmotes? channelEmotes,
    void Function(List<GenericEmote>)? onEmoteTap,
    double scale = 1.0,
  }) {
    if (channelEmotes == null) {
      return parseTextWithLinks(text);
    }

    final spans = <InlineSpan>[];
    final byCode = channelEmotes.byCode;

    final segments = _buildSegments(text, twitchPositions, byCode);
    if (segments.isEmpty) {
      return parseTextWithLinks(text);
    }

    EmoteSpanData? currentBase;
    int? currentBaseEnd;
    String? pendingSpace;

    void flushBase() {
      if (currentBase == null) return;
      spans.add(
        _buildEmoteSpan(currentBase!, onEmoteTap: onEmoteTap, scale: scale),
      );
      if (pendingSpace != null) {
        spans.addAll(parseTextWithLinks(pendingSpace!));
        pendingSpace = null;
      }
      currentBase = null;
      currentBaseEnd = null;
    }

    for (final seg in segments) {
      if (seg is TextSegment) {
        if (seg.text.trim().isEmpty) {
          pendingSpace = (pendingSpace ?? '') + seg.text;
        } else {
          flushBase();
          if (pendingSpace != null) {
            spans.addAll(parseTextWithLinks(pendingSpace!));
            pendingSpace = null;
          }
          spans.addAll(parseTextWithLinks(seg.text));
        }
      } else if (seg is EmoteSegment) {
        if (seg.emote.isZeroWidth) {
          if (currentBase != null && currentBaseEnd == seg.startIndex) {
            pendingSpace = null;
            currentBase = EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else if (currentBase != null &&
              pendingSpace != null &&
              currentBaseEnd == seg.startIndex - pendingSpace!.length) {
            pendingSpace = null;
            currentBase = EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else {
            flushBase();
            if (pendingSpace != null) {
              spans.addAll(parseTextWithLinks(pendingSpace!));
              pendingSpace = null;
            }
            currentBase = EmoteSpanData(base: seg.emote);
            currentBaseEnd = seg.endIndex;
          }
        } else {
          flushBase();
          if (pendingSpace != null) {
            spans.addAll(parseTextWithLinks(pendingSpace!));
            pendingSpace = null;
          }
          currentBase = EmoteSpanData(base: seg.emote);
          currentBaseEnd = seg.endIndex;
        }
      }
    }

    flushBase();

    if (pendingSpace != null) {
      spans.addAll(parseTextWithLinks(pendingSpace!));
    }

    return spans;
  }

  static List<_Segment> _buildSegments(
    String text,
    List<EmotePosition>? twitchPositions,
    Map<String, GenericEmote> byCode,
  ) {
    final segments = <_Segment>[];

    final sortedPos = twitchPositions != null
        ? (List<EmotePosition>.from(twitchPositions)
          ..sort((a, b) => a.startIndex.compareTo(b.startIndex)))
        : <EmotePosition>[];
    int twitchIdx = 0;

    EmotePosition? posAt(int i) {
      while (twitchIdx < sortedPos.length &&
          sortedPos[twitchIdx].endIndex <= i) {
        twitchIdx++;
      }
      if (twitchIdx < sortedPos.length &&
          i >= sortedPos[twitchIdx].startIndex) {
        return sortedPos[twitchIdx];
      }
      return null;
    }

    int i = 0;
    while (i < text.length) {
      final pos = posAt(i);
      if (pos != null) {
        final emoteCode = pos.emoteCode;
        final length = pos.endIndex - pos.startIndex;
        final emote = byCode[emoteCode];
        if (emote != null) {
          segments.add(
            EmoteSegment(emote: emote, startIndex: i, endIndex: i + length),
          );
        } else {
          segments.add(
            EmoteSegment(
              emote: GenericEmote(
                id: pos.emoteId,
                code: emoteCode,
                type: EmoteType.twitch,
                url:
                    'https://static-cdn.jtvnw.net/emoticons/v2/${pos.emoteId}/default/dark/3.0',
              ),
              startIndex: i,
              endIndex: i + length,
            ),
          );
        }
        i = pos.endIndex;
        continue;
      }

      if (text[i] == ' ' || text[i] == '\t' || text[i] == '\n') {
        final start = i;
        while (i < text.length &&
            (text[i] == ' ' || text[i] == '\t' || text[i] == '\n')) {
          i++;
        }
        segments.add(TextSegment(text: text.substring(start, i)));
        continue;
      }

      final start = i;
      while (i < text.length &&
          text[i] != ' ' &&
          text[i] != '\t' &&
          text[i] != '\n' &&
          posAt(i) == null) {
        i++;
      }
      final token = text.substring(start, i);

      final emote = byCode[token];
      if (emote != null) {
        segments.add(
          EmoteSegment(emote: emote, startIndex: start, endIndex: i),
        );
      } else {
        segments.add(TextSegment(text: token));
      }
    }

    return segments;
  }

  static Size _emoteSize(GenericEmote emote, double scale) {
    final s = min(28.0, 28.0 * emote.relativeScale) * scale;
    return Size(s * emote.aspectRatio, s);
  }

  static Widget _emoteImage(String url, double width, double height) {
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      placeholder: (_, _) => SizedBox(width: width, height: height),
      errorWidget: (_, _, _) => SizedBox(width: width, height: height),
    );
  }

  static WidgetSpan _buildEmoteSpan(EmoteSpanData data, {void Function(List<GenericEmote>)? onEmoteTap, double scale = 1.0}) {
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
        child: _emoteImage(data.base.url, baseSize.width, baseSize.height),
      ),
    ];
    for (final overlay in data.overlays) {
      final o = _emoteSize(overlay, scale);
      children.add(Positioned(
        left: (maxW - o.width) / 2,
        top: (maxH - o.height) / 2,
        width: o.width,
        height: o.height,
        child: _emoteImage(overlay.url, o.width, o.height),
      ));
    }
    Widget emoteWidget = Semantics(
      label: data.base.code,
      child: SizedBox(
        width: maxW,
        height: maxH,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
    if (onEmoteTap != null) {
      emoteWidget = GestureDetector(
        onTap: () => onEmoteTap([data.base, ...data.overlays]),
        child: emoteWidget,
      );
    }
    return WidgetSpan(alignment: PlaceholderAlignment.middle, child: emoteWidget);
  }
}

abstract class _Segment {
  int get startIndex;
  int get endIndex;
}

class TextSegment implements _Segment {
  final String text;

  @override
  int get startIndex => 0;

  @override
  int get endIndex => 0;

  const TextSegment({required this.text});
}

class EmoteSegment implements _Segment {
  final GenericEmote emote;
  @override
  final int startIndex;
  @override
  final int endIndex;

  const EmoteSegment({
    required this.emote,
    required this.startIndex,
    required this.endIndex,
  });
}

final _urlRegExp = RegExp(
  r'(?:https?://|www\.)[^\s<]+'
  r'|[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:/\S*)?',
);
final _collapseSpace = RegExp(r' {2,}');

List<InlineSpan> parseTextWithLinks(String text) {
  try {
    final collapsed = text.replaceAll(_collapseSpace, ' ');
    final spans = <InlineSpan>[];
    int lastEnd = 0;
    for (final match in _urlRegExp.allMatches(collapsed)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: collapsed.substring(lastEnd, match.start)));
      }
      var url = match.group(0)!;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Colors.blue),
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchUrl(Uri.parse(url)),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < collapsed.length) {
      spans.add(TextSpan(text: collapsed.substring(lastEnd)));
    }
    return spans;
  } catch (e, stack) {
    debugPrint('[parseTextWithLinks] error: $e');
    debugPrint('[parseTextWithLinks] text="$text"');
    debugPrint('[parseTextWithLinks] stack=$stack');
    return [TextSpan(text: text)];
  }
}
