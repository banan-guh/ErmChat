import '../../color_utils.dart';

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

/// System-message text for USERNOTICE. Announcements use the bare
/// [announcementLabel]; others use Twitch system-msg.
String buildUserNoticeText({
  required String msgId,
  required String displayName,
  required String announcementLabel,
  String? systemMsg,
}) {
  if (msgId == 'announcement') return announcementLabel;
  final base = systemMsg;
  if (base == null || base.isEmpty) return '$displayName $msgId.';
  return base;
}
