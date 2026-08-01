const _invisibleChar = '\u034F';

String bypassTextDuplicate(String text) {
  var i = 0;
  if (text.startsWith('/') || text.startsWith('.')) {
    i = 1;
  }
  final spaceIdx = text.indexOf(' ', i);
  if (spaceIdx >= 0) {
    return '${text.substring(0, spaceIdx + 1)} ${text.substring(spaceIdx + 1)}';
  }
  return '$text $_invisibleChar';
}
