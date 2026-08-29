/// Compact duration from seconds: "14d", "1h 30m", "45s". Zero -> "0s".
String formatSeconds(int totalSeconds) {
  if (totalSeconds <= 0) return '0s';
  final days = totalSeconds ~/ 86400;
  final hours = (totalSeconds % 86400) ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final parts = <String>[];
  if (days > 0) parts.add('${days}d');
  if (hours > 0) parts.add('${hours}h');
  if (minutes > 0) parts.add('${minutes}m');
  if (seconds > 0 || parts.isEmpty) parts.add('${seconds}s');
  return parts.join(' ');
}
