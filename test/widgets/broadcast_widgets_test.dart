import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/l10n/app_localizations.dart';
import 'package:ermchat/widgets/broadcast_widgets.dart';
import 'package:ermchat/widgets/chat_widget_cutout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
