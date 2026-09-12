import 'dart:ui' show Color;

import '../../color_utils.dart';
import '../../util/duration_format.dart';

/// Row accent for a USERNOTICE. Announcements use banner color; everything
/// else uses PRIMARY purple.
Color userNoticeAccent(String msgId, {String? announcementColorParam}) {
  if (msgId == 'announcement') {
    return announcementColorFor(announcementColorParam) ??
        announcementColors['PRIMARY']!;
  }
  return announcementColors['PRIMARY']!;
}

/// Composite label id for USERNOTICE. Namespaced so system label and chat
/// message stay distinct.
String? userNoticeLabelId(String? rawId) {
  if (rawId == null || rawId.isEmpty) return null;
  return '$rawId:label';
}

/// System-message text for USERNOTICE. Announcements use bare
/// "Announcement" label; others use Twitch system-msg.
String buildUserNoticeText({
  required String msgId,
  required String displayName,
  String? systemMsg,
}) {
  if (msgId == 'announcement') return 'Announcement';
  final base = systemMsg;
  if (base == null || base.isEmpty) return '$displayName $msgId.';
  return base;
}

/// Builds the system-message text for a CLEARCHAT ban/timeout.
String buildBanText({
  required String user,
  required bool isTimeout,
  int? durationSec,
}) {
  if (isTimeout) {
    return '$user was timed out${durationSec != null ? ' for ${formatSeconds(durationSec)}' : ''}.';
  }
  return '$user was banned.';
}
