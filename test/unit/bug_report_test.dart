import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/models/bug_report.dart';
import 'package:ermchat/util/diagnostics_scrub.dart';

void main() {
  BugReport report() => BugReport(
    id: 'id-12345678',
    createdAt: DateTime.utc(2026, 9, 28),
    kind: BugReportKind.bug,
    summary: '  App closes  ',
    whatHappened: 'It closed.',
    diagnostics: 'App: 0.9.0',
  );

  group('BugReport body', () {
    test('assembles filled sections; bug-only fields only go with bugs', () {
      final r = report()
        ..steps = 'Open chat'
        ..screenshots.add('https://kappa.lol/abc');
      final body = r.buildBody();
      expect(body, contains('### Description\n\nIt closed.'));
      expect(body, contains('### Steps to reproduce\n\nOpen chat'));
      expect(body, contains('### Screenshots\n\n![](https://kappa.lol/abc)'));
      expect(body, contains('<details><summary>Diagnostics</summary>'));
      expect(body, contains('App: 0.9.0'));

      final suggestion = r..kind = BugReportKind.suggestion;
      expect(
        suggestion.buildBody().trim(),
        '### Description\n\nIt closed.',
        reason: 'steps, screenshots and diagnostics hidden in the editor',
      );
    });

    test('only the title is required', () {
      expect((report()..whatHappened = '').isSendable, isTrue);
      expect((report()..summary = ' ').isSendable, isFalse);
      expect((report()..summary = 'x' * 201).isSendable, isFalse);
      expect(report().title, 'App closes');
    });

    test('drafts saved by older versions keep their text', () {
      final old = BugReport.fromJson({
        'id': 'id-12345678',
        'createdAt': '2026-09-28T00:00:00.000Z',
        'whatHappened': 'It closed.',
        'steps': '1. \n2. \n3. ',
        'expected': 'It stays open.',
        'kind': 'crash',
      })!;
      expect(old.whatHappened, 'It closed.\n\nExpected: It stays open.');
      expect(old.steps, '', reason: 'the untouched template is empty');
      expect(old.kind, BugReportKind.bug, reason: 'old problem kinds');
      final idea = BugReport.fromJson({...old.toJson(), 'kind': 'idea'})!;
      expect(idea.kind, BugReportKind.suggestion);
    });

    test('JSON round trip keeps every field', () {
      final r = report()
        ..status = BugReportStatus.sent
        ..issueNumber = 12
        ..issueUrl = 'https://github.com/o/r/issues/12'
        ..attempts = 2
        ..screenshots.add('https://kappa.lol/abc');
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
