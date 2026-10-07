import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/widgets/broadcast_widgets.dart';
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
    },
  );
}
