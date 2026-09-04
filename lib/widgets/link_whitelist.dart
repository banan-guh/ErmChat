import 'package:linkify/linkify.dart';

/// Linkifier for whitelisted domains stock linkify misses (short labels
/// like x.com) plus fractured/spaced links. Only matches
/// whitespace-hugging dots/slashes for fractures.
class WhitelistLinkifier extends Linkifier {
  final Set<String> _tlds;
  final Set<String> _domains;

  /// When false, spaced (fractured) runs are left alone; bare domains
  /// still link. Wired to the split-links toggle.
  final bool fractures;

  WhitelistLinkifier(List<String> whitelist, {this.fractures = true})
    : _tlds = {
        for (final e in whitelist)
          if (!e.contains('.')) e.toLowerCase(),
      },
      _domains = {
        for (final e in whitelist)
          if (e.contains('.')) e.toLowerCase(),
      };

  // Matches fractured (spaced) link runs. The lookahead scans across dots
  // and slashes so a space after a separator still counts as fractured.
  // Dots allow hugging spaces; a bare slash needs a glued path so the next
  // prose word is not eaten, while a spaced slash keeps fracture mode.
  static final _regex = RegExp(
    r'(?=(?:[A-Za-z0-9-./]|\s)*\s)'
    r'([A-Za-z0-9-]+(?:\s*\.\s*[A-Za-z0-9-._~%#+?=&]+)*'
    r'(?:\s+\/\s*[A-Za-z0-9-._~%#+?=&]*|\/[A-Za-z0-9-._~%#+?=&]*)*)',
    caseSensitive: false,
  );

  // Collapses spaces around dots/slashes.
  static final _spaceAround = RegExp(r'\s*([.\/])\s*');

  // Word-dot-space is a sentence boundary, not a fracture, unless pathed.
  static final _sentenceDot = RegExp(r'\S\.\s');
  static final _hasSpace = RegExp(r'\s');

  // True when the match runs straight into an email or scheme URL.
  static bool _gluedToLink(String text, int start) {
    if (start <= 0) return false;
    if (text[start - 1] == '@') return true;
    return start >= 3 &&
        text[start - 1] == '/' &&
        text[start - 2] == '/' &&
        text[start - 3] == ':';
  }

  @override
  List<LinkifyElement> parse(
    List<LinkifyElement> elements,
    LinkifyOptions options,
  ) {
    if (_tlds.isEmpty && _domains.isEmpty) return elements;
    final result = <LinkifyElement>[];
    for (final element in elements) {
      if (element is! TextElement) {
        result.add(element);
        continue;
      }
      _splitElement(element, result);
    }
    return result;
  }

  void _splitElement(TextElement element, List<LinkifyElement> out) {
    final text = element.text;
    final matches = _regex.allMatches(text).toList();
    if (matches.isEmpty) {
      out.add(element);
      return;
    }
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        out.add(TextElement(text.substring(lastEnd, m.start)));
      }
      final raw = m.group(1)!;
      final fractured = _hasSpace.hasMatch(raw);
      if (!raw.contains('.') ||
          _gluedToLink(text, m.start) ||
          (fractured && !fractures)) {
        // Plain word, part of an email/scheme URL, or fracture detection
        // is off: leave it to stock linkify.
        out.add(TextElement(raw));
        lastEnd = m.end;
        continue;
      }

      // Rejoin: collapse spaces around every dot and slash.
      final normalized = raw.replaceAllMapped(
        _spaceAround,
        (mm) => mm.group(1)!,
      );
      // Sentence dots need a path to count as a fracture.
      final needsPath = _sentenceDot.hasMatch(raw);
      final host = normalized.split('/').first.toLowerCase();
      final tld = host.split('.').last;
      final isWhitelisted =
          host.contains('.') &&
          (_tlds.contains(tld) ||
              _domains.any((d) => host == d || host.endsWith('.$d')));

      if (!isWhitelisted || (needsPath && !normalized.contains('/'))) {
        // Not opted in: leave the text as-is.
        out.add(TextElement(raw));
      } else if (fractured) {
        out.add(UrlElement('https://$normalized', raw));
      } else {
        // Bare links show without the scheme, like humanized stock links.
        out.add(UrlElement('https://$normalized', normalized, raw));
      }
      lastEnd = m.end;
    }
    if (lastEnd < text.length) {
      out.add(TextElement(text.substring(lastEnd)));
    }
  }
}

/// Links well-known single-char domains (x.com, t.co) stock linkify misses.
///
/// Own class on purpose: these are ordinary links, not spaced evasions, so
/// this runs always with no toggle or whitelist entry.
class SingleCharDomainLinkifier extends Linkifier {
  const SingleCharDomainLinkifier();

  static const domains = {'x.com', 't.co', 'q.com', 'z.com', 'a.co', 'x.org'};

  // One label char + dot + TLD + glued path. Lookbehind keeps emails,
  // scheme URLs, longer labels, and subdomains whole for other linkifiers.
  static final _regex = RegExp(
    r'(?<![A-Za-z0-9@:/.])([A-Za-z0-9]\.[A-Za-z]{2,}(?:\/[^\s]*)?)',
  );
  static final _trailingPunct = RegExp(r'[.,;:!?)]+$');

  @override
  List<LinkifyElement> parse(elements, options) {
    final result = <LinkifyElement>[];
    for (final element in elements) {
      if (element is! TextElement) {
        result.add(element);
        continue;
      }
      _splitElement(element.text, result);
    }
    return result;
  }

  void _splitElement(String text, List<LinkifyElement> out) {
    var lastEnd = 0;
    for (final m in _regex.allMatches(text)) {
      final raw = m.group(1)!;
      final shown = raw.replaceAll(_trailingPunct, '');
      if (!domains.contains(shown.split('/').first.toLowerCase())) continue;
      if (m.start > lastEnd) {
        out.add(TextElement(text.substring(lastEnd, m.start)));
      }
      out.add(UrlElement('https://$shown', shown, raw));
      lastEnd = m.start + shown.length;
    }
    if (lastEnd < text.length) {
      out.add(TextElement(text.substring(lastEnd)));
    }
  }
}

/// Email linkifier that leaves scheme URLs whole (https://user@host/ keeps
/// working). Runs before UrlLinkifier, which would eat the host half.
class SafeEmailLinkifier extends Linkifier {
  const SafeEmailLinkifier();

  static final _emailRegex = RegExp(
    r'^(.*?)((mailto:)?[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z][A-Z]+)',
    caseSensitive: false,
    dotAll: true,
  );
  static final _whitespace = RegExp(r'\s');
  static final _schemeInToken = RegExp(r'://');
  static final _mailtoPrefix = RegExp(r'mailto:');

  @override
  List<LinkifyElement> parse(elements, options) {
    final result = <LinkifyElement>[];
    for (final element in elements) {
      if (element is! TextElement) {
        result.add(element);
        continue;
      }
      _splitElement(element.text, result);
    }
    return result;
  }

  void _splitElement(String text, List<LinkifyElement> out) {
    final match = _emailRegex.firstMatch(text);
    if (match == null) {
      out.add(TextElement(text));
      return;
    }
    final before = match.group(1)!;
    final token = _tokenAround(text, match.start, match.end);
    if (_schemeInToken.hasMatch(text.substring(token.start, token.end))) {
      // Glued to a scheme URL: emit the whole token for UrlLinkifier.
      out.add(TextElement(text.substring(0, token.end)));
      final rest = text.substring(token.end);
      if (rest.isNotEmpty) _splitElement(rest, out);
      return;
    }
    if (before.isNotEmpty) out.add(TextElement(before));
    out.add(EmailElement(match.group(2)!.replaceFirst(_mailtoPrefix, '')));
    final rest = text.substring(match.end);
    if (rest.isNotEmpty) _splitElement(rest, out);
  }

  // Whitespace-delimited token holding the match.
  _TokenSpan _tokenAround(String text, int start, int end) {
    var s = start;
    while (s > 0 && !_whitespace.hasMatch(text[s - 1])) {
      s--;
    }
    var e = end;
    while (e < text.length && !_whitespace.hasMatch(text[e])) {
      e++;
    }
    return _TokenSpan(s, e);
  }
}

class _TokenSpan {
  final int start;
  final int end;

  const _TokenSpan(this.start, this.end);
}
