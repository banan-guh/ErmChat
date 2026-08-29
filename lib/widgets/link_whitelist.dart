import 'package:linkify/linkify.dart';

/// Linkifier that rejoins fractured/spaced links against a user whitelist. Only matches whitespace-hugging dots/slashes.
class WhitelistLinkifier extends Linkifier {
  final Set<String> _tlds;
  final Set<String> _domains;

  WhitelistLinkifier(List<String> whitelist)
      : _tlds = {
          for (final e in whitelist)
            if (!e.contains('.')) e,
        },
        _domains = {
          for (final e in whitelist)
            if (e.contains('.')) e,
        };

  // Matches fractured (spaced) link runs. Lookahead ensures bare links skip this.
  static final _regex = RegExp(
    r'(?=(?:[A-Za-z0-9-]|\s)*\s)'
    r'([A-Za-z0-9-]+(?:\s*[\.\/]\s*[A-Za-z0-9-._~%#+?=&]+)*)',
    caseSensitive: false,
  );

  // Collapses spaces around dots/slashes.
  static final _spaceAround = RegExp(r'\s*([.\/])\s*');

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

      // Rejoin: collapse spaces around every dot and slash.
      final normalized = raw.replaceAllMapped(_spaceAround, (mm) => mm.group(1)!);
      final host = normalized.split('/').first;
      final tld = host.split('.').last.toLowerCase();
      final isWhitelisted = _tlds.contains(tld) ||
          _domains.any((d) => host == d || host.endsWith('.$d'));

      if (!isWhitelisted) {
        // Not opted in: leave the fractured text as-is.
        out.add(TextElement(raw));
      } else {
        out.add(UrlElement('https://$normalized', raw));
      }
      lastEnd = m.end;
    }
    if (lastEnd < text.length) {
      out.add(TextElement(text.substring(lastEnd)));
    }
  }
}
