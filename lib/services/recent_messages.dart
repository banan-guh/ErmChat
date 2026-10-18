import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../l10n/l10n.dart';
import '../util/mod_activity_format.dart' show banNoticeText;
import '../util/constants.dart';
import '../util/prefs.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';
import '../util/fake_history.dart';
import '../util/log.dart';
import '../irc/decode/codec.dart'
    show parseIrcBadges, parseIrcChatMessage, parseIrcEmotePositions;
import '../irc/decode/copy.dart'
    show buildUserNoticeText, userNoticeAccent, userNoticeLabelId;
import '../irc/message.dart' show IrcMessage, parseIrcMessage;

/// Fetch failure. [definitive] = per-channel, no failover helps.
class RecentMessagesException implements Exception {
  RecentMessagesException(this.message, {this.definitive = false});

  final String message;
  final bool definitive;

  @override
  String toString() => message;
}

/// One decoded history response; [note] is the informational error text.
typedef HistoryBatch = ({
  List<TwitchMessage> messages,
  bool joined,
  String? note,
});

/// Recent-messages backend selector.
enum RecentMessagesMode { auto, robotty, zneix, custom }

/// Provider selection and failover order.
class RecentMessagesConfig {
  RecentMessagesConfig({this.mode = RecentMessagesMode.auto, this.customUrl})
    : assert(
        mode != RecentMessagesMode.custom || (customUrl?.isNotEmpty == true),
        'custom mode requires a non-empty customUrl',
      );

  final RecentMessagesMode mode;

  /// Base URL for [RecentMessagesMode.custom] (no trailing path).
  final String? customUrl;

  /// Ordered failover URLs.
  List<String> get providers {
    switch (mode) {
      case RecentMessagesMode.auto:
        return const [
          RecentMessagesService._baseUrl,
          RecentMessagesService._mirrorBaseUrl,
        ];
      case RecentMessagesMode.robotty:
        return const [RecentMessagesService._baseUrl];
      case RecentMessagesMode.zneix:
        return const [RecentMessagesService._mirrorBaseUrl];
      case RecentMessagesMode.custom:
        return [customUrl!];
    }
  }

  static RecentMessagesConfig fromPrefs(Prefs prefs) {
    final modeStr = prefs.recentMessagesModeName;
    final mode = RecentMessagesMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => RecentMessagesMode.auto,
    );
    final customUrl = prefs.recentMessagesCustomUrl;
    // Custom with no URL is invalid and behaves as Auto.
    if (mode == RecentMessagesMode.custom &&
        (customUrl == null || customUrl.isEmpty)) {
      return RecentMessagesConfig();
    }
    return RecentMessagesConfig(mode: mode, customUrl: customUrl);
  }

  Future<void> toPrefs(Prefs prefs) async {
    await prefs.setRecentMessagesModeName(mode.name);
    if (customUrl != null && customUrl!.isNotEmpty) {
      await prefs.setRecentMessagesCustomUrl(customUrl!);
    } else {
      await prefs.removeRecentMessagesCustomUrl();
    }
  }
}

class RecentMessagesService {
  static const _baseUrl =
      'https://recent-messages.robotty.de/api/v2/recent-messages';
  // Mirror of robotty; fallback on 5xx/network error or stale response.
  static const _mirrorBaseUrl =
      'https://recent-messages.zneix.eu/api/v2/recent-messages';

  /// Injectable HTTP client for tests.
  RecentMessagesService({
    http.Client? client,
    RecentMessagesConfig? config,
    this.strings = englishStrings,
    this.ownLogin = _noLogin,
  }) : _client = client, // ignore: prefer_initializing_formals
       _config = config ?? RecentMessagesConfig();

  final AppLocalizations Function() strings;

  /// Signed-in login, so the user's own ban lines read in the second person.
  final String? Function() ownLogin;

  static String? _noLogin() => null;

  final http.Client? _client;
  RecentMessagesConfig _config;

  /// The source setting; a change applies from the next fetch.
  set config(RecentMessagesConfig value) => _config = value;

  /// Launch-warmed history fetches (consumed once).
  static final Map<String, Future<List<TwitchMessage>>> _warmed = {};

  /// Warms history fetches at launch; duplicates ignored.
  static void warm(
    Iterable<String> channels, {
    int limit = 100,
    RecentMessagesConfig? config,
  }) {
    final service = RecentMessagesService(config: config);
    for (final channel in channels) {
      final key = channel.toLowerCase();
      if (_warmed.containsKey(key)) continue;
      // A failure before anyone awaits it must not surface as unhandled.
      _warmed[key] = service.fetchRecent(channel, limit: limit)..ignore();
    }
  }

  /// Returns warmed result or fresh fetch on miss/failure.
  Future<List<TwitchMessage>> fetchRecentPreferWarm(
    String channel, {
    int limit = 100,
  }) async {
    final warmed = _warmed.remove(channel.toLowerCase());
    if (warmed != null) {
      try {
        return await warmed;
      } catch (_) {
        // Refetched below.
      }
    }
    return fetchRecent(channel, limit: limit);
  }

  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    if (FakeHistory.isFake(channel)) return const [];
    final path =
        '/${Uri.encodeComponent(channel.toLowerCase())}'
        '?limit=${limit.clamp(1, 800)}';
    final providers = _config.providers;
    Object? lastError;
    List<TwitchMessage>? staleFallback;
    for (var i = 0; i < providers.length; i++) {
      try {
        final result = await _fetchFrom('${providers[i]}$path', channel);
        if (result.joined) return result.messages;
        // Not joined: the bot serves stale history, so a mirror that is
        // joined may have the correct messages. Keep the freshest stale
        // batch in case no provider is joined.
        logDebug(
          '[RecentMessages] provider ${i + 1} (${providers[i]}) '
          'not joined (stale) - trying next',
        );
        if (staleFallback == null ||
            _isFresher(result.messages, staleFallback)) {
          staleFallback = result.messages;
        }
      } on RecentMessagesException catch (e) {
        // Definitive: same API across providers, no failover.
        if (e.definitive) {
          logDebug(
            '[RecentMessages] $channel: ${e.message} '
            '(definitive - no failover)',
          );
          rethrow;
        }
        logDebug(
          '[RecentMessages] provider ${i + 1} (${providers[i]}) '
          'failed ($e) - trying next',
        );
        lastError = e;
      } catch (e) {
        logDebug(
          '[RecentMessages] provider ${i + 1} (${providers[i]}) '
          'failed ($e) - trying next',
        );
        lastError = e;
      }
    }
    // No joined provider: serve the freshest stale batch if there is one.
    if (staleFallback != null) return staleFallback;
    // All providers exhausted: surface last error or wrap.
    if (lastError is RecentMessagesException) throw lastError;
    throw RecentMessagesException(strings().historyLoadFailed);
  }

  /// True when [candidate] is newer than [current]. Non-empty beats empty,
  /// otherwise the latest timestamp wins. Both lists are timestamp-sorted.
  static bool _isFresher(
    List<TwitchMessage> candidate,
    List<TwitchMessage> current,
  ) {
    if (current.isEmpty) return candidate.isNotEmpty;
    if (candidate.isEmpty) return false;
    return candidate.last.timestamp.isAfter(current.last.timestamp);
  }

  Future<({List<TwitchMessage> messages, bool joined})> _fetchFrom(
    String url,
    String channel,
  ) async {
    final uri = Uri.parse(url);
    final ownClient = _client == null ? http.Client() : null;
    final client = _client ?? ownClient!;
    try {
      final res = await client.get(uri).timeout(httpTimeout);

      if (res.statusCode != 200) {
        // Parse JSON error codes for clean messages.
        var code = '';
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map<String, dynamic>) {
            code = decoded['error_code'] as String? ?? '';
          }
        } catch (_) {
          // Non-JSON: generic message.
        }
        final message = switch (code) {
          'invalid_channel_login' => strings().historyInvalidChannel,
          'channel_ignored' => strings().historyChannelExcluded,
          _ => strings().historyLoadFailed,
        };
        throw RecentMessagesException(
          message,
          definitive: res.statusCode == 400 || res.statusCode == 403,
        );
      }

      final batch = await parseBody(
        res.bodyBytes,
        channel,
        strings(),
        ownLogin(),
      );
      final note = batch.note;
      if (note != null) logDebug('[RecentMessages] $channel: $note');
      return (messages: batch.messages, joined: batch.joined);
    } finally {
      ownClient?.close();
    }
  }

  /// Message-line count at which a batch decodes in its own isolate.
  static const isolateLineThreshold = 200;

  /// Parses a 200 response body. Batches of [threshold] lines or more run in
  /// one isolate; the arguments are plain values so the closure captures no
  /// service state.
  @visibleForTesting
  static Future<HistoryBatch> parseBody(
    Uint8List bytes,
    String channel,
    AppLocalizations l,
    String? ownLogin, {
    int threshold = isolateLineThreshold,
  }) {
    if (_countLines(bytes) < threshold) {
      return Future.value(decodeBody(bytes, channel, l, ownLogin));
    }
    return Isolate.run(() => decodeBody(bytes, channel, l, ownLogin));
  }

  /// Counts array elements by their `","` separators, which occur unescaped
  /// only between JSON strings.
  static int _countLines(Uint8List bytes) {
    var n = 1;
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0x22 && bytes[i + 1] == 0x2C && bytes[i + 2] == 0x22) {
        n++;
      }
    }
    return n;
  }

  /// Decodes, parses, sweeps and sorts one history response.
  @visibleForTesting
  static HistoryBatch decodeBody(
    Uint8List bytes,
    String channel,
    AppLocalizations l,
    String? ownLogin,
  ) {
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    // Informational error_code on 200; not-joined means stale history.
    final joined = body['error_code'] != 'channel_not_joined';
    final note = body['error_code'] is String
        ? '${body['error']} (${body['error_code']})'
        : null;
    final rawMessages = body['messages'] as List<dynamic>?;
    if (rawMessages == null || rawMessages.isEmpty) {
      return (messages: <TwitchMessage>[], joined: joined, note: note);
    }

    final messages = <TwitchMessage>[];
    final clearMsgTargets = <String>{};
    for (final raw in rawMessages) {
      final rawLine = raw as String;
      final msg = parseIrcMessage(rawLine);
      if (msg == null) continue;
      // CLEARMSG: mark target deleted (applied after batch).
      if (msg.command == 'CLEARMSG') {
        final target = msg.tags['target-msg-id'];
        if (target != null && target.isNotEmpty) {
          clearMsgTargets.add(target);
        }
        continue;
      }
      // Announcement/sub notices render as child + label.
      final child = parseAnnouncementChildFromMsg(msg, channel: channel);
      if (child != null) messages.add(child);
      final subChild = parseSubChildFromMsg(msg, channel: channel);
      if (subChild != null) messages.add(subChild);
      final parsed = parseIrcLineFromMsg(
        msg,
        channel: channel,
        l: l,
        ownLogin: ownLogin,
      );
      if (parsed != null) messages.add(parsed);
    }

    // Ban sweep: only ban/timeout targets, not announcements.
    applyBanSweep(messages);
    applyMessageDeletions(messages, clearMsgTargets);

    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return (messages: messages, joined: joined, note: note);
  }

  /// Extracts deleted message id from CLEARMSG line.
  @visibleForTesting
  static String? clearMsgTargetId(String raw) {
    final msg = parseIrcMessage(raw);
    return clearMsgTargetIdFromMsg(msg);
  }

  /// Extracts deleted id from pre-parsed CLEARMSG.
  static String? clearMsgTargetIdFromMsg(IrcMessage? msg) {
    if (msg == null || msg.command != 'CLEARMSG') return null;
    final target = msg.tags['target-msg-id'];
    return (target == null || target.isEmpty) ? null : target;
  }

  /// Marks CLEARMSG deletions (survive restart).
  @visibleForTesting
  static void applyMessageDeletions(
    List<TwitchMessage> messages,
    Iterable<String> targetIds,
  ) {
    final targets = targetIds.toSet();
    if (targets.isEmpty) return;
    for (final msg in messages) {
      if (!msg.isSystem &&
          msg.messageId != null &&
          targets.contains(msg.messageId)) {
        msg.deleted = true;
      }
    }
  }

  /// Ban sweep: deletes prior messages from banned user.
  @visibleForTesting
  static void applyBanSweep(List<TwitchMessage> messages) {
    final latestBan = <String, DateTime>{};
    for (final msg in messages) {
      if (!msg.isBanNotice || msg.login.isEmpty) continue;
      final seen = latestBan[msg.login];
      if (seen == null || msg.timestamp.isAfter(seen)) {
        latestBan[msg.login] = msg.timestamp;
      }
    }
    if (latestBan.isEmpty) return;
    for (final other in messages) {
      if (other.isSystem) continue;
      final ban = latestBan[other.login];
      if (ban != null && !ban.isBefore(other.timestamp)) other.deleted = true;
    }
  }

  static TwitchMessage? parseIrcLine(
    String raw, {
    String? channel,
    AppLocalizations? l,
    String? ownLogin,
  }) {
    final msg = parseIrcMessage(raw);
    return parseIrcLineFromMsg(msg, channel: channel, l: l, ownLogin: ownLogin);
  }

  static TwitchMessage? parseIrcLineFromMsg(
    IrcMessage? msg, {
    String? channel,
    AppLocalizations? l,
    String? ownLogin,
  }) {
    if (msg == null) return null;
    l ??= englishStrings();
    switch (msg.command) {
      case 'PRIVMSG':
        return _parsePrivmsg(msg, channel);
      case 'CLEARCHAT':
        return _parseClearChat(msg, channel, l, ownLogin);
      case 'USERNOTICE':
        return _parseUserNotice(msg, channel, l);
      case 'NOTICE':
        return _parseNotice(msg, channel);
      default:
        return null;
    }
  }

  static TwitchMessage? _parseNotice(IrcMessage msg, String? channel) {
    final text = msg.trailing;
    if (text == null || text.isEmpty) return null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: '',
      text: text,
      isSystem: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parsePrivmsg(IrcMessage msg, String? channel) {
    final tsMs = msg.tags['rm-received-ts'];
    final timestamp = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : null;

    final parsed = parseIrcChatMessage(
      msg,
      channel: channel,
      timestamp: timestamp,
      isHistory: true,
    );

    // Junk: no display name and no text.
    final rawDisplayName = msg.tags['display-name'] ?? '';
    if (rawDisplayName.isEmpty && parsed.text.isEmpty) return null;
    return parsed;
  }

  static TwitchMessage? _parseClearChat(
    IrcMessage msg,
    String? channel,
    AppLocalizations l,
    String? ownLogin,
  ) {
    // Robotty strips trailing colon.
    final targetUser =
        msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null);
    if (targetUser == null || targetUser.isEmpty) return null;

    final banDuration = msg.tags['ban-duration'];
    final isTimeout = banDuration != null;
    final durationSec = isTimeout ? int.tryParse(banDuration) : null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: targetUser,
      text: l.banLine(
        banNoticeText(
          l,
          user: targetUser,
          isTimeout: isTimeout,
          durationSec: durationSec,
          self: targetUser.toLowerCase() == ownLogin?.toLowerCase(),
        ),
      ),
      isSystem: true,
      isBanNotice: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parseUserNotice(
    IrcMessage msg,
    String? channel,
    AppLocalizations l,
  ) {
    var msgId = msg.tags['msg-id'] ?? '';
    if (msgId.isEmpty) return null;
    // Drop mirrored shared-chat notices except announcements.
    if (msgId == 'sharedchatnotice') {
      final sourceMsgId = msg.tags['source-msg-id'];
      if (sourceMsgId != 'announcement') return null;
      msgId = 'announcement';
    }
    // Only announcements carry login; empty prevents false ban sweep.
    final isAnnouncement = msgId == 'announcement';
    final login = isAnnouncement ? (msg.tags['login'] ?? '') : '';
    final displayName = msg.tags['display-name'] ?? login;
    final systemMsg =
        msg.tags['system-msg'] != null && msg.tags['system-msg']!.isNotEmpty
        ? msg.tags['system-msg']
        : null;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();
    // Robotty strips trailing colon.
    final text = msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null);
    final isSubWithText =
        (msgId == 'sub' || msgId == 'resub') &&
        (text?.trim().isNotEmpty ?? false);

    return TwitchMessage(
      login: login,
      text: buildUserNoticeText(
        msgId: msgId,
        displayName: displayName,
        announcementLabel: l.announcementLabel,
        systemMsg: systemMsg,
      ),
      isSystem: true,
      // Namespaced id avoids collision with child message.
      messageId: userNoticeLabelId(msg.tags['id']),
      // Announcements use banner accent; others default purple.
      systemAccent: isAnnouncement
          ? userNoticeAccent(
              'announcement',
              announcementColorParam: msg.tags['msg-param-color'],
            )
          : userNoticeAccent(msgId),
      channel: channel,
      // +1ms so child sorts above label.
      timestamp: isAnnouncement || isSubWithText
          ? ts.add(const Duration(milliseconds: 1))
          : ts,
      isHistory: true,
    );
  }

  /// Child message for sub/resub with text, or null.
  @visibleForTesting
  static TwitchMessage? parseSubChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    return parseSubChildFromMsg(msg, channel: channel);
  }

  static TwitchMessage? parseSubChildFromMsg(
    IrcMessage? msg, {
    String? channel,
  }) {
    if (msg == null || msg.command != 'USERNOTICE') return null;
    final msgId = msg.tags['msg-id'];
    if (msgId != 'sub' && msgId != 'resub') return null;
    // Robotty strips trailing colon.
    final text =
        (msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null))
            ?.trim();
    if (text == null || text.isEmpty) return null;

    final login = (msg.tags['login'] ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: login,
      displayName: displayName,
      text: text,
      color: msg.tags['color'],
      userId: msg.tags['user-id'],
      messageId: msg.tags['id'],
      badges: parseIrcBadges(msg.tags['badges']),
      emotePositions: parseIrcEmotePositions(
        msg.tags['emotes'],
        originalText: text,
        strippedText: text,
      ),
      systemAccent: announcementColors['PRIMARY'],
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  /// Child message for announcement USERNOTICE, or null.
  @visibleForTesting
  static TwitchMessage? parseAnnouncementChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    return parseAnnouncementChildFromMsg(msg, channel: channel);
  }

  static TwitchMessage? parseAnnouncementChildFromMsg(
    IrcMessage? msg, {
    String? channel,
  }) {
    if (msg == null || msg.command != 'USERNOTICE') return null;
    // Mirrored shared-chat announcements: real type in source-msg-id.
    final rawMsgId = msg.tags['msg-id'];
    if (rawMsgId != 'announcement' &&
        !(rawMsgId == 'sharedchatnotice' &&
            msg.tags['source-msg-id'] == 'announcement')) {
      return null;
    }
    // Robotty strips trailing colon.
    final text =
        (msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null))
            ?.trim();
    if (text == null || text.isEmpty) return null;

    final login = (msg.tags['login'] ?? '').toLowerCase();
    final displayName = msg.tags['display-name'] ?? login;

    final tsMs = msg.tags['rm-received-ts'];
    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    return TwitchMessage(
      login: login,
      displayName: displayName,
      text: text,
      color: msg.tags['color'],
      userId: msg.tags['user-id'],
      messageId: msg.tags['id'],
      badges: parseIrcBadges(msg.tags['badges']),
      emotePositions: parseIrcEmotePositions(
        msg.tags['emotes'],
        originalText: text,
        strippedText: text,
      ),
      systemAccent:
          announcementColorFor(msg.tags['msg-param-color']) ??
          announcementColors['PRIMARY'],
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }
}
