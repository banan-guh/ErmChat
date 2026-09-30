import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ermchat/models/bug_report.dart';
import 'package:ermchat/providers/feature_providers.dart';
import 'package:ermchat/screens/settings/report_bug_screen.dart';
import 'package:ermchat/services/bug_report_outbox.dart';

void main() {
  late Directory dir;
  late BugReportOutbox outbox;
  final bodies = <Map<String, dynamic>>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('report_ui');
    bodies.clear();
    outbox = BugReportOutbox(
      endpoint: 'https://bot.test/report',
      accessToken: () => 'tok',
      directory: dir,
      client: MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'issue': 3, 'url': 'https://x/issues/3', 'thread': 't'}),
          200,
        );
      }),
    );
  });

  tearDown(() {
    outbox.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<BugReport> openEditor(WidgetTester tester) async {
    final draft = outbox.newDraft(diagnostics: 'App: 0.9.0');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bugReportOutboxProvider.overrideWithValue(outbox)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReportEditorScreen(report: draft),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return draft;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  // The outbox persists through real file I/O. Each I/O hop completes only
  // while real time passes, and its continuation only runs on a pump, so
  // alternate the two until the chain (write, rename, send) is through.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  // FilledButton.icon builds a private subclass, so match by subtype.
  final sendButton = find.byWidgetPredicate((w) => w is FilledButton);

  // The button sits below the fold of a lazy list. Multiline fields own
  // Scrollables too, so name the list's own.
  Future<void> scrollToSend(WidgetTester tester) => tester.scrollUntilVisible(
    sendButton,
    200,
    scrollable: find.byType(Scrollable).first,
  );

  testWidgets('sending assembles the fields into one report', (tester) async {
    final draft = await openEditor(tester);
    await tester.enterText(field('Summary *'), 'Header sticks');
    await tester.enterText(field('What you expected'), 'It goes away');
    await scrollToSend(tester);
    // Send stays disabled until the required fields are filled.
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
    await tester.scrollUntilVisible(
      field('What happened *'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(field('What happened *'), 'It stayed');
    await tester.pump();
    await scrollToSend(tester);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);
    await tester.tap(sendButton);
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(bodies, hasLength(1));
    expect(bodies.single['id'], draft.id);
    expect(bodies.single['title'], 'Header sticks');
    final body = bodies.single['body'] as String;
    expect(body, contains('### What happened\n\nIt stayed'));
    expect(body, contains('### Expected\n\nIt goes away'));
    expect(body, contains('App: 0.9.0'));
    expect(outbox.byId(draft.id)?.status, BugReportStatus.sent);
    // The editor closed back to the opener.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('leaving with text keeps a draft, blank leaves nothing', (
    tester,
  ) async {
    final draft = await openEditor(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(outbox.reports, isEmpty);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Summary *'), 'Half written');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(outbox.byId(draft.id)?.status, BugReportStatus.draft);
    expect(outbox.byId(draft.id)?.summary, 'Half written');
    expect(bodies, isEmpty);
  });
}
