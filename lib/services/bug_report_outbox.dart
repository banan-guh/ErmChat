import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/bug_report.dart';
import '../util/log.dart';

/// Local store and send queue for in-app bug reports.
///
/// Drafts and queued reports persist to one JSON file, so nothing is lost
/// offline or across restarts. [flush] sends queued reports one at a time;
/// each carries its stable id, so a resend after a lost response returns
/// the first result instead of opening a second issue.
class BugReportOutbox extends ChangeNotifier {
  BugReportOutbox({
    required this.endpoint,
    required this.accessToken,
    this.secret = '',
    http.Client? client,
    Directory? directory,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _dir = directory;

  /// ermchatbot `POST /report` URL. Empty disables sending.
  final String endpoint;
  final String secret;

  /// Current Twitch user token; null while signed out.
  final String? Function() accessToken;

  final http.Client _client;
  final bool _ownsClient;
  Directory? _dir;

  /// Newest first.
  final List<BugReport> _reports = [];
  bool _loaded = false;
  bool _flushing = false;
  bool _disposed = false;
  Timer? _retryTimer;

  /// Covers a free-tier server waking from sleep (about a minute).
  static const sendTimeout = Duration(seconds: 90);

  /// Sent reports kept for the history list.
  static const maxSentKept = 50;

  List<BugReport> get reports => List.unmodifiable(_reports);

  BugReport? byId(String id) {
    for (final r in _reports) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return;
      final list = jsonDecode(await file.readAsString());
      if (list is! List) return;
      for (final item in list) {
        if (item is! Map) continue;
        final r = BugReport.fromJson(Map<String, dynamic>.from(item));
        if (r != null) _reports.add(r);
      }
      _notify();
    } catch (e) {
      // A corrupt file must not block the app; the outbox starts empty.
      logDebug('[BugReportOutbox] load failed: $e');
    }
  }

  /// A fresh draft with pre-filled [diagnostics]. Not stored until saved.
  BugReport newDraft({String diagnostics = ''}) => BugReport(
    id: _uuidV4(),
    createdAt: DateTime.now(),
    diagnostics: diagnostics,
  );

  /// Stores [report] as a draft (insert or replace).
  Future<void> saveDraft(BugReport report) async {
    report.status = BugReportStatus.draft;
    _upsert(report);
    await _persist();
  }

  Future<void> delete(String id) async {
    _reports.removeWhere((r) => r.id == id);
    _notify();
    await _persist();
  }

  /// Queues [report] and tries to send it now.
  Future<void> submit(BugReport report) async {
    report
      ..status = BugReportStatus.queued
      ..lastError = null
      ..attempts = 0;
    _upsert(report);
    await _persist();
    await flush();
  }

  /// Sends every queued report. Safe to call often (app start, network
  /// back, sign-in): overlapping calls collapse into the running pass.
  Future<void> flush() async {
    if (_flushing || _disposed || endpoint.isEmpty) return;
    _flushing = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    Duration? retryIn;
    try {
      for (final r in _reports.reversed.toList()) {
        if (_disposed) return;
        if (r.status != BugReportStatus.queued) continue;
        final token = accessToken();
        if (token == null) {
          r.lastError = 'Sign in to send';
          break;
        }
        final wait = await _send(r, token);
        await _persist();
        if (wait != null) {
          retryIn = wait;
          // The server or network is down; later reports would fail too.
          break;
        }
      }
    } finally {
      _flushing = false;
      _notify();
    }
    if (retryIn != null && !_disposed) {
      _retryTimer = Timer(retryIn, () => unawaited(flush()));
    }
  }

  /// Sends one report and records the outcome on it. Returns how long to
  /// wait before retrying, or null when the report reached a final state
  /// (or needs the user, like an expired sign-in).
  Future<Duration?> _send(BugReport r, String token) async {
    final http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              if (secret.isNotEmpty) 'X-Report-Secret': secret,
            },
            body: jsonEncode({
              'id': r.id,
              'title': r.title,
              'body': r.buildBody(),
            }),
          )
          .timeout(sendTimeout);
    } catch (_) {
      return _retryable(r, 'Waiting for connection');
    }
    final code = resp.statusCode;
    if (code == 200) {
      final json = _decode(resp.body);
      r
        ..status = BugReportStatus.sent
        ..issueNumber = json['issue'] as int?
        ..issueUrl = json['url'] as String?
        ..lastError = null
        ..attempts = 0;
      _trimSent();
      return null;
    }
    final message = _decode(resp.body)['error'] as String?;
    if (code == 401) {
      // Stays queued; the next sign-in (auth change) flushes again.
      r.lastError = 'Twitch sign-in expired; sign in again to send';
      return null;
    }
    if (code == 429) {
      r.lastError = 'Daily report limit reached; will retry';
      final after = int.tryParse(resp.headers['retry-after'] ?? '');
      return Duration(seconds: after ?? 3600);
    }
    if (code >= 400 && code < 500) {
      r
        ..status = BugReportStatus.failed
        ..lastError = message ?? 'Rejected by the server ($code)';
      return null;
    }
    return _retryable(r, 'Server unavailable; will retry');
  }

  /// Backoff for transient failures: 1, 2, 4 ... minutes, capped at an hour.
  Duration _retryable(BugReport r, String message) {
    r
      ..lastError = message
      ..attempts += 1;
    final minutes = min(60, 1 << min(r.attempts - 1, 6));
    return Duration(minutes: minutes);
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : const {};
    } catch (_) {
      return const {};
    }
  }

  void _trimSent() {
    var kept = 0;
    _reports.removeWhere(
      (r) => r.status == BugReportStatus.sent && ++kept > maxSentKept,
    );
  }

  void _upsert(BugReport report) {
    final i = _reports.indexWhere((r) => r.id == report.id);
    if (i >= 0) {
      _reports[i] = report;
    } else {
      _reports.insert(0, report);
    }
    _notify();
  }

  Future<File?> _file() async {
    try {
      _dir ??= await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
    return File('${_dir!.path}${Platform.pathSeparator}bug_reports.json');
  }

  Future<void> _persist() async {
    try {
      final file = await _file();
      if (file == null) return;
      final json = jsonEncode([for (final r in _reports) r.toJson()]);
      // Write-then-rename so a kill mid-write cannot corrupt the outbox.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      logDebug('[BugReportOutbox] persist failed: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _uuidV4() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
