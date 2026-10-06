import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/l10n.dart';

class NotificationService {
  NotificationService({AppLocalizations Function()? strings})
    : _strings = strings ?? englishStrings;

  final AppLocalizations Function() _strings;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final _tapController = StreamController<String>.broadcast();
  String? _pendingLaunchChannel;
  // Monotonic suffix for distinct IDs within the same second.
  int _idSeq = 0;

  Stream<String> get onNotificationTap => _tapController.stream;
  String? get pendingLaunchChannel => _pendingLaunchChannel;

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onResponse,
    );

    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      _pendingLaunchChannel = details?.notificationResponse?.payload;
    }

    final l = _strings();
    final androidChannel = AndroidNotificationChannel(
      'chat_mentions',
      l.sectionMentions,
      description: l.notifChannelDesc,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      _tapController.add(payload);
    }
  }

  static const _groupKey = 'chat_mentions_group';
  // Fixed summary ID; individual IDs are epoch seconds (no collision).
  static const _summaryId = 1;

  // Per-channel notification ids + ordered summary lines.
  final _idsByChannel = <String, List<int>>{};
  final _postedIds = <int>{};
  final _summaryOrder = <int>[];
  final _summaryLineById = <int, String>{};

  // Only the last few lines ever render (InboxStyleInformation shows 5), so
  // retain a bounded window instead of every mention of the session.
  static const _maxSummaryLines = 50;

  // Total mentions this session, kept separately so the summary count stays
  // right after [_summaryOrder] is trimmed.
  int _summaryTotal = 0;

  Future<void> showMentionNotification({
    required String channel,
    required String userName,
    required String message,
  }) async {
    final body = _truncate(message);
    await _post(
      channel: channel,
      title: _strings().notifPingedYou(userName, channel),
      body: body,
      payload: channel,
      summaryLine: '$userName: $body',
    );
  }

  Future<void> showWhisperNotification({
    required String userName,
    required String message,
  }) async {
    final body = _truncate(message);
    await _post(
      channel: null,
      title: _strings().notifWhisper(userName),
      body: body,
      payload: null,
      summaryLine: _strings().notifWhisperSummary(userName, body),
    );
  }

  Future<void> _post({
    required String? channel,
    required String title,
    required String body,
    required String? payload,
    required String summaryLine,
  }) async {
    final l = _strings();
    final androidDetails = AndroidNotificationDetails(
      'chat_mentions',
      l.sectionMentions,
      channelDescription: l.notifChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      groupKey: _groupKey,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000 + _idSeq++;
    _postedIds.add(id);
    if (channel != null) {
      _idsByChannel.putIfAbsent(channel, () => []).add(id);
    }
    _summaryOrder.add(id);
    _summaryLineById[id] = summaryLine;
    _summaryTotal++;
    if (_summaryOrder.length > _maxSummaryLines) {
      _summaryLineById.remove(_summaryOrder.removeAt(0));
    }

    await _plugin.show(id, title, body, details, payload: payload);
    await _updateSummary();
  }

  Future<void> _updateSummary() async {
    if (_summaryOrder.isEmpty) {
      await _plugin.cancel(_summaryId);
      return;
    }
    final lines = [for (final id in _summaryOrder) _summaryLineById[id]!];
    final l = _strings();
    final androidDetails = AndroidNotificationDetails(
      'chat_mentions',
      l.sectionMentions,
      channelDescription: l.notifChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      groupKey: _groupKey,
      setAsGroupSummary: true,
      styleInformation: InboxStyleInformation(
        lines.length > 5 ? lines.sublist(lines.length - 5) : lines,
        contentTitle: l.notifNewMentions,
        summaryText: l.notifMentionCount(_summaryTotal),
      ),
      // Summary alerts only; children stay silent.
      playSound: false,
      enableVibration: false,
    );
    await _plugin.show(
      _summaryId,
      null,
      null,
      NotificationDetails(android: androidDetails),
    );
  }

  static String _truncate(String message) =>
      message.length > 200 ? '${message.substring(0, 200)}...' : message;

  /// Cancels mention notifications (all or per-channel).
  Future<void> clearMentionNotifications([String? channel]) async {
    Iterable<int> ids;
    if (channel == null) {
      ids = List.of(_postedIds);
    } else {
      ids = List.of(_idsByChannel[channel] ?? const <int>[]);
      _idsByChannel.remove(channel);
    }
    final removedFromSummary = <int>{};
    for (final id in ids) {
      await _plugin.cancel(id);
      _postedIds.remove(id);
      if (_summaryLineById.remove(id) != null) removedFromSummary.add(id);
    }
    if (removedFromSummary.isNotEmpty) {
      _summaryOrder.removeWhere(removedFromSummary.contains);
    }
    if (channel == null) {
      _summaryTotal = 0;
    } else {
      _summaryTotal -= removedFromSummary.length;
      if (_summaryTotal < 0) _summaryTotal = 0;
    }
    if (_summaryOrder.isEmpty) {
      await _plugin.cancel(_summaryId);
    } else if (removedFromSummary.isNotEmpty) {
      await _updateSummary();
    }
  }

  void dispose() {
    _tapController.close();
  }
}
