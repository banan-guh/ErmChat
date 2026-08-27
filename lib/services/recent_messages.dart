import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../util/constants.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';
import '../util/log.dart';
import 'twitch_irc.dart';

/// History fetch failure with a user-presentable message. [definitive]
/// marks per-channel answers (invalid login, excluded channel) where trying
/// the mirror cannot succeed.
class RecentMessagesException implements Exception {
  RecentMessagesException(
    this.message, {
    this.errorCode,
    this.definitive = false,
  });

  final String message;
  final String? errorCode;
  final bool definitive;

  @override
  String toString() => message;
}

/// Which recent-messages backend(s) to query.
enum RecentMessagesMode { auto, robotty, zneix, custom }

/// Selects the recent-messages provider(s) and their failover order.
///
/// [auto] queries robotty then its zneix mirror and gives up once both fail;
/// the forced modes query exactly one source (no automatic switching); [custom]
/// queries a user-supplied base URL.
class RecentMessagesConfig {
  RecentMessagesConfig({this.mode = RecentMessagesMode.auto, this.customUrl})
    : assert(
        mode != RecentMessagesMode.custom || (customUrl?.isNotEmpty == true),
        'custom mode requires a non-empty customUrl',
      );

  final RecentMessagesMode mode;

  /// Base URL for [RecentMessagesMode.custom] (no trailing path).
  final String? customUrl;

  /// Ordered base URLs to attempt, in failover order.
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

  static RecentMessagesConfig fromPrefs(SharedPreferences prefs) {
    final modeStr = prefs.getString('recent_messages_mode') ?? 'auto';
    final mode = RecentMessagesMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => RecentMessagesMode.auto,
    );
    final customUrl = prefs.getString('recent_messages_custom_url');
    if (mode == RecentMessagesMode.custom ||
        customUrl == null ||
        customUrl.isEmpty) {
      return RecentMessagesConfig();
    }
    return RecentMessagesConfig(mode: mode, customUrl: customUrl);
  }

  Future<void> toPrefs(SharedPreferences prefs) async {
    await prefs.setString('recent_messages_mode', mode.name);
    if (customUrl != null && customUrl!.isNotEmpty) {
      await prefs.setString('recent_messages_custom_url', customUrl!);
    } else {
      await prefs.remove('recent_messages_custom_url');
    }
  }
}

class RecentMessagesService {
  static const _baseUrl =
      'https://recent-messages.robotty.de/api/v2/recent-messages';
  // Mirror of the same service (robotty/recent-messages2) hosted by zneix.
  // Falls back here when the primary is unavailable (5xx / network error).
  static const _mirrorBaseUrl =
      'https://recent-messages.zneix.eu/api/v2/recent-messages';

  /// Injectable HTTP client for tests.
  // Private named parameters cannot be initializing formals.
  RecentMessagesService({http.Client? client, RecentMessagesConfig? config})
    : _client = client, // ignore: prefer_initializing_formals
      _config = config ?? RecentMessagesConfig();

  final http.Client? _client;
  final RecentMessagesConfig _config;

  /// History fetches started at launch, keyed by lowercase channel name.
  /// Consumed once by [fetchRecentPreferWarm].
  static final Map<String, Future<List<TwitchMessage>>> _warmed = {};

  /// Starts history fetches as early as possible (app launch) so results are
  /// usually ready by the time the UI asks. Duplicate channels are ignored;
  /// failures are rethrown at consume time.
  static void warm(
    Iterable<String> channels, {
    int limit = 100,
    RecentMessagesConfig? config,
  }) {
    final service = RecentMessagesService(config: config);
    var armed = 0;
    for (final channel in channels) {
      final key = channel.toLowerCase();
      if (_warmed.containsKey(key)) continue;
      _warmed[key] = service.fetchRecent(channel, limit: limit);
      armed++;
    }
    if (armed > 0) {
      PerfLog.I.record('PERF', 'history warm fired: $armed');
    }
  }

  /// Returns the warmed result for [channel] when available (consuming it),
  /// falling back to a fresh [fetchRecent] on miss or warm failure: a launch
  /// second spent offline must not surface as "Failed to load chat history"
  /// when the network recovered two seconds later.
  Future<List<TwitchMessage>> fetchRecentPreferWarm(
    String channel, {
    int limit = 100,
  }) async {
    final sw = Stopwatch()..start();
    final warmed = _warmed.remove(channel.toLowerCase());
    if (warmed != null) {
      try {
        final history = await warmed;
        PerfLog.I.record(
          'PERF',
          'history warm hit $channel '
              '(waited ${sw.elapsedMilliseconds}ms)',
        );
        return history;
      } catch (_) {
        PerfLog.I.record(
          'PERF',
          'history warm failed $channel '
              '(after ${sw.elapsedMilliseconds}ms), refetching',
        );
      }
    }
    return fetchRecent(channel, limit: limit);
  }

  Future<List<TwitchMessage>> fetchRecent(
    String channel, {
    int limit = 100,
  }) async {
    final path =
        '/${Uri.encodeComponent(channel.toLowerCase())}'
        '?limit=${limit.clamp(1, 800)}';
    final providers = _config.providers;
    Object? lastError;
    for (var i = 0; i < providers.length; i++) {
      try {
        return await _fetchFrom('${providers[i]}$path', channel);
      } on RecentMessagesException catch (e) {
        // Definitive per-channel answers (invalid login, excluded channel):
        // every provider serves the same API and would fail identically.
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
    // All providers exhausted: surface the last error as-is when it was a
    // clean RecentMessagesException, otherwise wrap so the UI stays friendly.
    if (lastError is RecentMessagesException) throw lastError;
    throw RecentMessagesException('Failed to load chat history');
  }

  Future<List<TwitchMessage>> _fetchFrom(String url, String channel) async {
    final uri = Uri.parse(url);
    final res = await (_client ?? http.Client()).get(uri).timeout(httpTimeout);

    if (res.statusCode != 200) {
      // Error bodies are JSON with machine-readable codes:
      // 400 invalid_channel_login, 403 channel_ignored. Surface a clean
      // message instead of the raw status line.
      var code = '';
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          code = decoded['error_code'] as String? ?? '';
        }
      } catch (_) {
        // Non-JSON body: fall through to the generic message.
      }
      final message = switch (code) {
        'invalid_channel_login' => 'Invalid channel name',
        'channel_ignored' =>
          'History unavailable: channel excluded from the history service',
        _ => 'Failed to load chat history',
      };
      throw RecentMessagesException(
        message,
        errorCode: code.isEmpty ? null : code,
        definitive: res.statusCode == 400 || res.statusCode == 403,
      );
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    // Informational only per the API docs: e.g. channel_not_joined on a 200
    // still carries whatever history exists. Never surfaced to users.
    if (body['error_code'] is String) {
      logDebug(
        '[RecentMessages] $channel: ${body['error']} '
        '(${body['error_code']})',
      );
    }
    final rawMessages = body['messages'] as List<dynamic>?;
    if (rawMessages == null || rawMessages.isEmpty) return [];

    final messages = <TwitchMessage>[];
    final clearMsgTargets = <String>{};
    for (final raw in rawMessages) {
      final rawLine = raw as String;
      // CLEARMSG lines don't render themselves; they mark the target
      // message as deleted (applied after the batch is parsed).
      final target = clearMsgTargetId(rawLine);
      if (target != null) {
        clearMsgTargets.add(target);
        continue;
      }
      // Announcement USERNOTICEs render as two entries, like the live view:
      // the child message (announcement text as a normal message) followed
      // by the "Announcement" label. Sub/resub notices with a user message
      // do the same so emotes render in the child.
      final child = parseAnnouncementChild(rawLine, channel: channel);
      if (child != null) messages.add(child);
      final subChild = parseSubChild(rawLine, channel: channel);
      if (subChild != null) messages.add(subChild);
      final parsed = parseIrcLine(rawLine, channel: channel);
      if (parsed != null) messages.add(parsed);
    }

    // Only ban/timeout system messages sweep prior messages from the
    // target user; announcements carry a login too but must not delete
    // anything.
    applyBanSweep(messages);
    applyMessageDeletions(messages, clearMsgTargets);

    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  /// Extracts the deleted message id from a CLEARMSG history line, or null.
  @visibleForTesting
  static String? clearMsgTargetId(String raw) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'CLEARMSG') return null;
    final target = msg.tags['target-msg-id'];
    return (target == null || target.isEmpty) ? null : target;
  }

  /// Marks messages deleted by CLEARMSG history lines (deletions must
  /// survive a restart like every other event).
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

  /// Marks messages deleted when a later ban/timeout system message targets
  /// the same login. Exposed for tests; `isBanNotice` keeps announcements
  /// (which legitimately carry a login) out of the sweep.
  @visibleForTesting
  static void applyBanSweep(List<TwitchMessage> messages) {
    for (final msg in messages) {
      if (msg.isBanNotice && msg.login.isNotEmpty) {
        final targetUser = msg.login;
        for (final other in messages) {
          if (!other.isSystem &&
              other.login == targetUser &&
              !msg.timestamp.isBefore(other.timestamp)) {
            other.deleted = true;
          }
        }
      }
    }
  }

  static TwitchMessage? parseIrcLine(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null) return null;
    switch (msg.command) {
      case 'PRIVMSG':
        return _parsePrivmsg(msg, channel);
      case 'CLEARCHAT':
        return _parseClearChat(msg, channel);
      case 'USERNOTICE':
        return _parseUserNotice(msg, channel);
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

    // Lines with neither a display name nor any text are junk.
    final rawDisplayName = msg.tags['display-name'] ?? '';
    if (rawDisplayName.isEmpty && parsed.text.isEmpty) return null;
    return parsed;
  }

  static TwitchMessage? _parseClearChat(IrcMessage msg, String? channel) {
    // Robotty strips the trailing colon for single-word payloads.
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
      text: buildBanText(
        user: targetUser,
        isTimeout: isTimeout,
        durationSec: durationSec,
      ),
      isSystem: true,
      isBanNotice: true,
      channel: channel,
      timestamp: ts,
      isHistory: true,
    );
  }

  static TwitchMessage? _parseUserNotice(IrcMessage msg, String? channel) {
    var msgId = msg.tags['msg-id'] ?? '';
    if (msgId.isEmpty) return null;
    // Shared chat mirrors foreign USERNOTICEs as `sharedchatnotice`; drop
    // them except announcements (DankChat-style clutter reduction), matching
    // the live IRC path.
    if (msgId == 'sharedchatnotice') {
      final sourceMsgId = msg.tags['source-msg-id'];
      if (sourceMsgId != 'announcement') return null;
      msgId = 'announcement';
    }
    // Only announcements carry a meaningful login; other notices keep it
    // empty so the ban deletion sweep in fetchRecent never treats them as
    // ban targets (the sweep also keys on isBanNotice, so this is belt and
    // braces).
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
    // Robotty strips the trailing colon for single-word payloads.
    final text = msg.trailing ?? (msg.params.length > 1 ? msg.params[1] : null);
    final isSubWithText =
        (msgId == 'sub' || msgId == 'resub') &&
        (text?.trim().isNotEmpty ?? false);

    return TwitchMessage(
      login: login,
      text: buildUserNoticeText(
        msgId: msgId,
        displayName: displayName,
        systemMsg: systemMsg,
      ),
      isSystem: true,
      // Namespaced notice id so the label dedups against its live twin
      // without colliding with the child chat message that shares the raw
      // USERNOTICE id.
      messageId: userNoticeLabelId(msg.tags['id']),
      // Announcements carry their banner accent; every other notice
      // (subscriptions, gift subs, watch streaks, bits badge tiers, raids,
      // pay forwards, ...) highlights like a default (PRIMARY) purple
      // announcement.
      systemAccent: isAnnouncement
          ? userNoticeAccent(
              'announcement',
              announcementColorParam: msg.tags['msg-param-color'],
            )
          : userNoticeAccent(msgId),
      channel: channel,
      // 1ms after the child message so the sorted history keeps the child
      // above the label (List.sort is not stable).
      timestamp: isAnnouncement || isSubWithText
          ? ts.add(const Duration(milliseconds: 1))
          : ts,
      isHistory: true,
    );
  }

  /// The child chat message for a sub/resub USERNOTICE line that carries a
  /// user message (the message rendered as a normal chat message so emotes
  /// render), or null when the line is not a sub/resub with text.
  @visibleForTesting
  static TwitchMessage? parseSubChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'USERNOTICE') return null;
    final msgId = msg.tags['msg-id'];
    if (msgId != 'sub' && msgId != 'resub') return null;
    // Robotty strips the trailing colon for single-word payloads.
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

  /// The child chat message for an announcement USERNOTICE line (the
  /// announcement text rendered as a normal message, DankChat-style), or
  /// null when the line is not an announcement with text.
  @visibleForTesting
  static TwitchMessage? parseAnnouncementChild(String raw, {String? channel}) {
    final msg = parseIrcMessage(raw);
    if (msg == null || msg.command != 'USERNOTICE') return null;
    // Mirrored shared-chat announcements arrive as `sharedchatnotice` with
    // the real type in `source-msg-id`; they render like native ones.
    final rawMsgId = msg.tags['msg-id'];
    if (rawMsgId != 'announcement' &&
        !(rawMsgId == 'sharedchatnotice' &&
            msg.tags['source-msg-id'] == 'announcement')) {
      return null;
    }
    // Robotty strips the trailing colon for single-word payloads.
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
