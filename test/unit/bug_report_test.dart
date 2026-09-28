import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/models/bug_report.dart';
import 'package:ermchat/util/diagnostics_scrub.dart';

void main() {
  BugReport report() => BugReport(
    id: 'id-12345678',
    createdAt: DateTime.utc(2026, 9, 28),
    kind: BugReportKind.crash,
    summary: '  App closes  ',
    whatHappened: 'It closed.',
    expected: 'It stays open.',
    diagnostics: 'App: 0.9.0',
  );

  group('BugReport body', () {
    test('assembles filled sections and skips template steps', () {
      final body = report().buildBody();
      expect(body, contains('**Type:** Crash'));
      expect(body, contains('### What happened\n\nIt closed.'));
      expect(body, contains('### Expected\n\nIt stays open.'));
      expect(body, isNot(contains('Steps to reproduce')));
      expect(body, contains('<details><summary>Diagnostics</summary>'));
      expect(body, contains('App: 0.9.0'));
    });

    test('includes edited steps and honors the diagnostics toggle', () {
      final r = report()
        ..steps = '1. Open chat\n2. Swipe'
        ..includeDiagnostics = false;
      final body = r.buildBody();
      expect(body, contains('### Steps to reproduce\n\n1. Open chat'));
      expect(body, isNot(contains('Diagnostics')));
    });

    test('requires summary and description', () {
      expect(report().isSendable, isTrue);
      expect((report()..summary = ' ').isSendable, isFalse);
      expect((report()..whatHappened = '').isSendable, isFalse);
      expect((report()..summary = 'x' * 201).isSendable, isFalse);
      expect(report().title, 'App closes');
    });

    test('JSON round trip keeps every field', () {
      final r = report()
        ..status = BugReportStatus.sent
        ..issueNumber = 12
        ..issueUrl = 'https://github.com/o/r/issues/12'
        ..attempts = 2;
      final back = BugReport.fromJson(r.toJson())!;
      expect(back.toJson(), r.toJson());
      expect(BugReport.fromJson({'id': 'x'}), isNull);
    });
  });

  test('scrubDiagnostics removes credentials', () {
    const raw =
        'PASS oauth:abc123\n'
        'Authorization: Bearer tok_1\n'
        'GET https://api.example.com/x?access_token=secret&y=1\n'
        'redirect#access_token=zzz\n'
        'plain line';
    final out = scrubDiagnostics(raw);
    for (final leak in ['abc123', 'tok_1', 'secret', 'zzz']) {
      expect(out, isNot(contains(leak)));
    }
    expect(out, contains('https://api.example.com/x?[redacted]'));
    expect(out, contains('plain line'));
  });
}
