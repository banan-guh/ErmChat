/// Decodes a Twitch IRCv3 tag value. Escapes: \s->space, \::>;;, \\->backslash, \r, \n. Single-pass so \\s -> \s, not `\ ` (backslash-space).
String unescapeIrcTag(String raw) {
  if (!raw.contains(r'\')) return raw;
  final buf = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final ch = raw[i];
    if (ch == r'\' && i + 1 < raw.length) {
      final next = raw[i + 1];
      switch (next) {
        case 's':
          buf.write(' ');
        case ':':
          buf.write(';');
        case r'\':
          buf.write(r'\');
        case 'r':
          buf.write('\r');
        case 'n':
          buf.write('\n');
        default:
          // Unknown escape: keep both characters verbatim.
          buf.write(ch);
          buf.write(next);
      }
      i += 2;
    } else {
      buf.write(ch);
      i++;
    }
  }
  return buf.toString();
}
