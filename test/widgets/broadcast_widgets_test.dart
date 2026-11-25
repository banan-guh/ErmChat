import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/l10n/app_localizations.dart';
import 'package:ermchat/widgets/broadcast_widgets.dart';
import 'package:ermchat/widgets/chat_widget_cards.dart';
import 'package:ermchat/widgets/chat_widget_cutout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget overlayApp(BroadcastWidgets widgets, ValueNotifier<double> room) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([room, widgets.notifier]),
            builder: (_, _) =>
                widgets.buildOverlay(
                  'c',
                  room: room.value,
                  onMinimizeChanged: widgets.setMinimized,
                ) ??
                const SizedBox(),
          ),
        ),
      );

  testWidgets(
    'timed pins lapse, unpins remove their own pin, dismissals stick',
    (tester) async {
      final widgets = BroadcastWidgets(selectedChannel: () => 'c');
      addTearDown(widgets.dispose);
      PinnedMessageEvent pin(
        String id, {
        Duration? lasts,
        bool removed = false,
      }) => PinnedMessageEvent(
        channel: 'c',
        id: id,
        messageId: 'm$id',
        text: 'hi',
        endsAt: lasts == null ? null : DateTime.now().add(lasts),
        removed: removed,
      );

      widgets.onPinned(pin('a', lasts: const Duration(seconds: 30)));
      widgets.onPinned(pin('old', removed: true));
      expect(widgets.pins['c']?.id, 'a', reason: 'unpin of another pin');

      await tester.pump(const Duration(seconds: 31));
      expect(widgets.pins, isEmpty, reason: 'timed pin outlived ends_at');

      widgets.onPinned(pin('b'));
      widgets.onPinned(pin('b', removed: true));
      expect(widgets.pins, isEmpty);

      widgets.onPinned(pin('c'));
      widgets.dismissPin('c');
      widgets.onPinned(pin('c'));
      expect(widgets.pins, isEmpty, reason: 'a dismissed pin pushed again');
      widgets.onPinned(pin('d'));
      expect(widgets.pins['c']?.id, 'd', reason: 'a new pin after a dismiss');

      widgets.onPinned(PinnedMessageEvent(channel: 'c', id: '', removed: true));
      expect(widgets.pins, isEmpty, reason: 'Helix read found no pin');

      for (final timed in [false, true]) {
        final refreshes = <String>[];
        final refreshing = BroadcastWidgets(
          selectedChannel: () => 'c',
          onPinRefresh: refreshes.add,
        );
        addTearDown(refreshing.dispose);

        refreshing.onPinned(
          PinnedMessageEvent(
            channel: 'c',
            id: 'a',
            messageId: 'ma',
            text: 'hi',
            endsAt: timed ? DateTime.now().add(const Duration(hours: 1)) : null,
          ),
        );
        await tester.pump(const Duration(minutes: 5));
        expect(
          refreshes,
          ['c'],
          reason: timed
              ? 'a timed pin can be unpinned early'
              : 'an untimed pin outlives a missed unpin',
        );

        refreshing.onPinned(
          PinnedMessageEvent(channel: 'c', id: 'a', removed: true),
        );
        await tester.pump(const Duration(minutes: 5));
        expect(refreshes, ['c'], reason: 'a removed pin stops refreshing');
      }

      final switched = <String>[];
      var selected = 'c';
      final switching = BroadcastWidgets(
        selectedChannel: () => selected,
        onPinRefresh: switched.add,
      );
      addTearDown(switching.dispose);
      for (final channel in ['c', 'd']) {
        switching.onPinned(
          PinnedMessageEvent(channel: channel, id: channel, text: 'hi'),
        );
      }
      await tester.pump(const Duration(minutes: 5));
      expect(switched, ['c'], reason: 'background pins are not re-read');

      selected = 'd';
      switching.onSelectionChanged('d');
      await tester.pump(const Duration(minutes: 5));
      expect(switched, ['c', 'd'], reason: 'selection moves the re-read');

      selected = 'c';
      switching.onSelectionChanged('c');
      await tester.pump(const Duration(minutes: 5));
      expect(switched, ['c', 'd', 'c'], reason: 'a returning pin resumes it');
      switching.onSelectionChanged(null);

      final cards = BroadcastWidgets(selectedChannel: () => 'c');
      addTearDown(cards.dispose);
      cards.onPinned(PinnedMessageEvent(channel: 'c', id: 'a', text: 'hi'));
      final room = ValueNotifier(600.0);
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([room, cards.notifier]),
              builder: (_, _) =>
                  cards.buildOverlay(
                    'c',
                    room: room.value,
                    onMinimizeChanged: cards.setMinimized,
                  ) ??
                  const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ChatWidgetCutout), findsOneWidget);

      room.value = 40;
      await tester.pump();
      expect(
        find.byType(ChatWidgetMinimizedBar),
        findsOneWidget,
        reason: 'the keyboard leaves no room for the card',
      );

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(
        find.byType(ChatWidgetCutout),
        findsOneWidget,
        reason: 'a restore while cramped stays open',
      );

      room.value = 600;
      await tester.pump();
      room.value = 40;
      await tester.pump();
      expect(
        find.byType(ChatWidgetMinimizedBar),
        findsOneWidget,
        reason: 'the next keyboard folds it again',
      );
    },
  );

  testWidgets('one surface ink target survives fold and restore', (
    tester,
  ) async {
    final widgets = BroadcastWidgets(selectedChannel: () => 'c');
    addTearDown(widgets.dispose);
    widgets.onPinned(
      PinnedMessageEvent(channel: 'c', id: 'a', text: 'pin body'),
    );
    final room = ValueNotifier(600.0);
    addTearDown(room.dispose);
    await tester.pumpWidget(overlayApp(widgets, room));
    await tester.pumpAndSettle();

    final surface = find.byType(ChatWidgetSurface);
    expect(surface, findsOneWidget);
    Finder inkTarget() => find.byWidgetPredicate(
      (w) =>
          w is InkWell &&
          (w.child is ChatWidgetCutout || w.child is ChatWidgetMinimizedBar),
    );
    expect(inkTarget(), findsOneWidget);
    final element = inkTarget().evaluate().single;
    expect(find.byType(ChatWidgetCutout), findsOneWidget);

    // The pin text is part of the card, not a control.
    await tester.tap(find.byType(PinnedMessageText));
    await tester.pumpAndSettle();
    expect(find.byType(ChatWidgetMinimizedBar), findsOneWidget);
    expect(
      inkTarget().evaluate().single,
      same(element),
      reason: 'the press target is not rebuilt by the swap',
    );

    await tester.tap(find.byType(PinnedMessageText));
    await tester.pumpAndSettle();
    expect(find.byType(ChatWidgetCutout), findsOneWidget);
    expect(inkTarget().evaluate().single, same(element));
  });

  testWidgets('restore returns to the focused card and page', (tester) async {
    final widgets = BroadcastWidgets(selectedChannel: () => 'c');
    addTearDown(widgets.dispose);
    widgets.onPinned(
      PinnedMessageEvent(channel: 'c', id: 'a', text: 'pin body'),
    );
    widgets.onPoll(
      PollEvent(
        channel: 'c',
        kind: PollKind.progress,
        rawKind: 'progress',
        title: 'A poll title',
        choices: [PollChoice(title: 'yes', votes: 1)],
        status: 'ACTIVE',
      ),
    );
    final room = ValueNotifier(600.0);
    addTearDown(room.dispose);
    await tester.pumpWidget(overlayApp(widgets, room));
    await tester.pumpAndSettle();

    widgets.pageCtrlFor('c').jumpToPage(1);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.byType(ChatWidgetMinimizedBar), findsOneWidget);
    expect(find.text('A poll title'), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.byType(ChatWidgetCutout), findsOneWidget);
    expect(
      widgets.pageCtrlFor('c').initialPage,
      1,
      reason: 'restore opens on the focused page',
    );
  });

  testWidgets('pin menu tap leaves the card open', (tester) async {
    final widgets = BroadcastWidgets(selectedChannel: () => 'c');
    addTearDown(widgets.dispose);
    widgets.onPinned(
      PinnedMessageEvent(channel: 'c', id: 'a', text: 'pin body'),
    );
    final room = ValueNotifier(600.0);
    addTearDown(room.dispose);
    await tester.pumpWidget(overlayApp(widgets, room));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    expect(
      find.byType(ChatWidgetCutout),
      findsOneWidget,
      reason: 'the menu button is not the card press target',
    );
    Navigator.of(tester.element(find.byType(ChatWidgetSurface))).pop();
    await tester.pumpAndSettle();
  });
}
