import '../util/irc_utils.dart';
import '../util/log.dart';

final _loneLowSurrogateRe = RegExp(r'[\uDC00-\uDFFF]');
final _orphanedHighSurrogateRe = RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])');

/// Whether [s] holds any UTF-16 surrogate unit. Most tag values are ASCII,
/// so this skips both regex passes for them.
bool _hasSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) & 0xF800 == 0xD800) return true;
  }
  return false;
}

/// A single parsed IRC frame: tags, prefix, command, params and trailing.
class IrcMessage {
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> params;
  final String? trailing;

  IrcMessage({
    required this.tags,
    this.prefix,
    required this.command,
    required this.params,
    this.trailing,
  });
}

/// Parses one raw IRC line into an [IrcMessage]. Returns null when the line
/// has no usable frame (missing separator, or an unparseable shape).
IrcMessage? parseIrcMessage(String line) {
  try {
    String? tags;
    String? prefix;
    String? trailing;

    int pos = 0;

    if (line.startsWith('@')) {
      final end = line.indexOf(' ');
      if (end == -1) return null;
      tags = line.substring(1, end);
      pos = end + 1;
    }

    if (pos < line.length && line[pos] == ':') {
      final end = line.indexOf(' ', pos);
      if (end == -1) return null;
      prefix = line.substring(pos + 1, end);
      pos = end + 1;
    }

    // The trailing param starts at the first " :", so the message body is
    // sliced once instead of split per word and rejoined.
    final trailingAt = line.indexOf(' :', pos);
    final head = line.substring(pos, trailingAt == -1 ? null : trailingAt);
    if (trailingAt != -1) trailing = line.substring(trailingAt + 2);
    final parts = head.split(' ');
    final command = parts[0];
    final params = parts.sublist(1);

    final tagMap = <String, String>{};
    if (tags != null) {
      for (final tag in tags.split(';')) {
        final eq = tag.indexOf('=');
        if (eq != -1) {
          // Twitch IRCv3 tags are backslash-escaped, not percent-encoded.
          String decoded = unescapeIrcTag(tag.substring(eq + 1));
          // Strip orphaned UTF-16 surrogates: low surrogates alone or high
          // surrogates not followed by low (Flutter's text engine crashes on
          // isolated surrogates from malformed Twitch IRC data).
          if (_hasSurrogate(decoded)) {
            decoded = decoded.replaceAll(_loneLowSurrogateRe, '');
            decoded = decoded.replaceAll(_orphanedHighSurrogateRe, '');
          }
          tagMap[tag.substring(0, eq)] = decoded;
        }
      }
    }

    return IrcMessage(
      tags: tagMap,
      prefix: prefix,
      command: command,
      params: params,
      trailing: trailing,
    );
  } catch (_) {
    logDebug('[parseIrcMessage] failed to parse line: $line');
    return null;
  }
}
