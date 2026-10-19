import 'package:ermchat/l10n/l10n.dart';
import 'package:ermchat/util/history_timeline.dart';
import 'package:ermchat/widgets/history_days.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('show in calendar keeps its day when the rail rebuilds', (
    tester,
  ) async {
    final from = DateTime(2026, 10, 1);
    ActivityRail railTo(DateTime to) => ActivityRail(
      from: from,
      to: to,
      bucket: const Duration(hours: 1),
      counts: List.filled(to.difference(from).inHours, 1),
    );
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    final kept = ValueNotifier<Set<int>>({});
    addTearDown(kept.dispose);
    final stream = DateTime(2026, 10, 2, 14);
    DateTime? openTime = stream;
    Widget app(ActivityRail rail) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: HistoryDays(
          rail: rail,
          open: open,
          viewTime: () => null,
          onPick: (_) {},
          kept: kept,
          onLongPress: (_) {},
          takeOpenTime: () {
            final t = openTime;
            openTime = null;
            return t;
          },
        ),
      ),
    );

    await tester.pumpWidget(app(railTo(DateTime(2026, 10, 4))));
    // The calendar opens on the stream before the rebuilt rail lands, as
    // the history view does when its rail is stale.
    open.value = true;
    await tester.pumpWidget(app(railTo(DateTime(2026, 10, 4, 1))));
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.arrow_back),
      findsOneWidget,
      reason: 'the rebuilt rail dropped the stream day back to the list',
    );
  });
}
