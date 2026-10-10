import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ermchat/models/bug_report.dart';
import 'package:ermchat/services/bug_report_outbox.dart';

void main() {
  late Directory dir;
  final outboxes = <BugReportOutbox>[];
  final requests = <http.Request>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bug_reports');
    requests.clear();
  });

  tearDown(() {
    for (final o in outboxes) {
      o.dispose();
    }
    outboxes.clear();
    dir.deleteSync(recursive: true);
  });

  BugReportOutbox outbox(
    Future<http.Response> Function(http.Request) handler, {
    String? token = 'tok',
  }) {
    final o = BugReportOutbox(
      endpoint: 'https://bot.test/report',
      accessToken: () => token,
      client: MockClient((req) {
        requests.add(req);
        return handler(req);
      }),
      directory: dir,
    );
    outboxes.add(o);
    return o;
  }

  BugReport draft(BugReportOutbox o) => o.newDraft()
    ..summary = 'Crash on open'
    ..whatHappened = 'It closed';

  http.Response ok(int issue) => http.Response(
    jsonEncode({
      'issue': issue,
      'url': 'https://github.com/o/r/issues/$issue',
      'thread': 't',
    }),
    200,
  );

  test('sends with token and id, then records the issue', () async {
    final o = outbox((_) async => ok(7));
    final r = draft(o);
    await o.submit(r);

    expect(requests, hasLength(1));
    final req = requests.single;
    expect(req.headers['Authorization'], 'Bearer tok');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['id'], r.id);
    expect(body['title'], 'Crash on open');
    expect(body['body'], contains('### Description'));
    expect(r.status, BugReportStatus.sent);
    expect(r.issueNumber, 7);
    expect(r.issueUrl, 'https://github.com/o/r/issues/7');
  });

  test(
    'offline keeps it queued and a later flush reuses the same id',
    () async {
      var online = false;
      final o = outbox((_) async {
        if (!online) throw const SocketException('offline');
        return ok(8);
      });
      final r = draft(o);
      await o.submit(r);
      expect(r.status, BugReportStatus.queued);
      expect(r.attempts, 1);

      online = true;
      await o.flush();
      expect(r.status, BugReportStatus.sent);
      final ids = requests.map((q) => jsonDecode(q.body)['id']).toSet();
      expect(ids, {r.id});
    },
  );

  test(
    'server errors retry, client errors fail, 401 waits for sign-in',
    () async {
      var code = 502;
      final o = outbox(
        (_) async => http.Response(jsonEncode({'error': 'nope'}), code),
      );
      final r = draft(o);
      await o.submit(r);
      expect(r.status, BugReportStatus.queued);

      code = 401;
      await o.flush();
      expect(r.status, BugReportStatus.queued);
      expect(r.lastError, contains('sign in'));

      code = 400;
      await o.flush();
      expect(r.status, BugReportStatus.failed);
      expect(r.lastError, 'nope');
    },
  );

  test('nothing is sent while signed out', () async {
    final o = outbox((_) async => ok(1), token: null);
    final r = draft(o);
    await o.submit(r);
    expect(requests, isEmpty);
    expect(r.status, BugReportStatus.queued);
    expect(r.lastError, 'Sign in to send');
  });

  test('drafts and queued reports survive a restart', () async {
    final first = outbox((_) async => throw const SocketException('offline'));
    final d = draft(first);
    await first.saveDraft(d);
    final q = draft(first)..summary = 'Queued one';
    await first.submit(q);

    final second = outbox((_) async => ok(9));
    await second.load();
    expect(second.byId(d.id)?.status, BugReportStatus.draft);
    expect(second.byId(q.id)?.status, BugReportStatus.queued);

    await second.flush();
    expect(second.byId(q.id)?.status, BugReportStatus.sent);
    expect(second.byId(d.id)?.status, BugReportStatus.draft);
  });

  test('status check updates sent reports, drops deleted ones', () async {
    var clock = DateTime(2026, 10, 9);
    var issue = 0;
    late String keptId, deletedId;
    final o = BugReportOutbox(
      endpoint: 'https://bot.test/report',
      accessToken: () => 'tok',
      directory: dir,
      now: () => clock,
      client: MockClient((req) async {
        requests.add(req);
        if (!req.url.path.endsWith('/status')) return ok(++issue);
        return http.Response(
          jsonEncode({
            'reports': [
              {'id': keptId, 'status': 'fixed', 'replies': 2},
              {'id': deletedId, 'gone': true},
            ],
          }),
          200,
        );
      }),
    );
    outboxes.add(o);
    final kept = draft(o);
    final deleted = draft(o);
    keptId = kept.id;
    deletedId = deleted.id;
    await o.submit(kept);
    await o.submit(deleted);
    final unsent = draft(o);
    await o.saveDraft(unsent);
    requests.clear();

    await o.refreshStatus();
    expect(
      jsonDecode(requests.single.body)['ids'],
      unorderedEquals([kept.id, deleted.id]),
      reason: 'only sent reports have an issue to check',
    );
    expect(kept.issueStatus, 'fixed');
    expect(kept.hasNewReplies, isTrue);
    expect(o.byId(deleted.id), isNull);
    expect(o.byId(unsent.id), isNotNull);

    await o.markSeen(kept.id);
    expect(kept.hasNewReplies, isFalse);

    await o.refreshStatus();
    expect(requests, hasLength(1), reason: 'throttled');
    clock = clock.add(BugReportOutbox.statusInterval);
    await o.refreshStatus();
    expect(requests, hasLength(2));
  });
}
