import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/screens/settings/analytics_screen.dart';
import 'package:ermchat/services/analytics_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  AnalyticsService seededService() {
    final service = AnalyticsService();
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'alice', text: 'hello world', channel: 'chan1'),
    );
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'bob', text: 'hello', channel: 'chan1'),
    );
    service.recordMessage(
      'chan2',
      TwitchMessage(login: 'carol', text: 'yo', channel: 'chan2'),
    );
    return service;
  }

  Widget wrap(AnalyticsService service, List<String> channels) {
    return MaterialApp(
      home: AnalyticsScreen(analyticsService: service, channels: channels),
    );
  }

  testWidgets('shows empty state when no channels', (tester) async {
    await tester.pumpWidget(wrap(AnalyticsService(), []));
    await tester.pump();
    expect(find.text('Join a channel to start tracking stats'), findsOneWidget);
  });

  testWidgets('renders summary and top lists for the first channel', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(seededService(), ['chan1', 'chan2']));
    await tester.pump();

    expect(find.text('Total messages'), findsOneWidget);
    expect(find.text('Unique chatters'), findsOneWidget);
    expect(find.text('Messages per minute'), findsOneWidget);
    expect(find.text('Tracking for'), findsOneWidget);
    expect(find.text('Top chatters'), findsOneWidget);
    expect(find.text('Top emotes'), findsOneWidget);
    expect(find.text('Top words'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('channel selector switches the displayed stats', (tester) async {
    await tester.pumpWidget(wrap(seededService(), ['chan1', 'chan2']));
    await tester.pump();

    expect(find.text('carol'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, 'chan2'));
    await tester.pumpAndSettle();

    expect(find.text('carol'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('stopword toggle filters common words', (tester) async {
    final service = AnalyticsService();
    service.recordMessage(
      'chan',
      TwitchMessage(login: 'alice', text: 'the hello', channel: 'chan'),
    );
    await tester.pumpWidget(wrap(service, ['chan']));
    await tester.pump();

    expect(find.text('the'), findsOneWidget);

    await tester.tap(find.text('Filter common words'));
    await tester.pump();

    expect(find.text('the'), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('reset this channel clears the stats', (tester) async {
    final service = seededService();
    await tester.pumpWidget(wrap(service, ['chan1', 'chan2']));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Reset this channel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    expect(service.trackingStartedAt('chan1'), isNull);
  });

  testWidgets('shows moderation counts when bans occur', (tester) async {
    final service = AnalyticsService();
    service.recordModeration('chan', false);
    service.recordModeration('chan', true);
    await tester.pumpWidget(wrap(service, ['chan']));
    await tester.pump();

    expect(find.text('Moderation'), findsOneWidget);
    expect(find.text('Bans'), findsOneWidget);
    expect(find.text('Timeouts'), findsOneWidget);
  });
}
