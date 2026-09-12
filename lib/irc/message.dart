import '../util/irc_utils.dart';
import '../util/log.dart';

final _loneLowSurrogateRe = RegExp(r'[\uDC00-\uDFFF]');
final _orphanedHighSurrogateRe = RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])');

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
    String command;
    List<String> params = [];
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

    final rest = line.substring(pos);
    final parts = rest.split(' ');
    command = parts[0];

    int i = 1;
    while (i < parts.length) {
      if (parts[i].startsWith(':')) {
        trailing = parts.sublist(i).join(' ').substring(1);
        break;
      }
      params.add(parts[i]);
      i++;
    }

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
          decoded = decoded.replaceAll(_loneLowSurrogateRe, '');
          decoded = decoded.replaceAll(_orphanedHighSurrogateRe, '');
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
