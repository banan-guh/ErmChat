import 'package:linkify/linkify.dart';

/// linkify [Linkifier] that rejoins and links **fractured/split** links
/// whose TLD (or full domain) is in a user whitelist — the anti-evasion case
/// where a link is typed with spaces to dodge a "no links" filter, e.g.
/// `kappa . lol / EMGIU`, `i .nuuls .com/ ABCD`, or `7tv .app /emotes /abc`.
///
/// This is intentionally NOT a general bare-domain whitelist: a plain
/// `kappa.lol` (no space) is left to linkify's own default handling. Only
/// forms with whitespace hugging a dot or slash are matched here.
///
/// Matching rules (the whitelist is the gate):
///  - entry WITHOUT a dot (e.g. `lol`)  -> matches any split `*.lol`
///  - entry WITH a dot    (e.g. `kappa.lol`) -> matches that split domain and
///    its subdomains (so `sub .kappa.lol` links too)
///  - a negative lookbehind excludes matches inside `http(s)://`, `www.`,
///    and email addresses.
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

  // Captures a link-like run where dots and slashes are fractured by
  // whitespace (multi-label, multi-path).  The lookahead ensures at least one
  // space is present so bare links ("kappa.lol") skip straight to linkify's
  // own default handler and are never consumed here.
  static final _regex = RegExp(
    r'(?=(?:[A-Za-z0-9-]|\s)*\s)'
    r'([A-Za-z0-9-]+(?:\s*[\.\/]\s*[A-Za-z0-9-._~%#+?=&]+)*)',
    caseSensitive: false,
  );

  // Collapses spaces around dots and slashes: "kappa . lol / EMGIU" ->
  // "kappa.lol/EMGIU".
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
