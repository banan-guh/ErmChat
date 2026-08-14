import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/widgets/emote_menu_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GenericEmote sevenTv(String id, String code) => GenericEmote(
    id: id,
    code: code,
    type: EmoteType.sevenTv,
    url: 'https://example.com/$id.png',
    scope: EmoteScope.channel,
  );

  Widget wrap(EmoteManager manager) {
    return MaterialApp(
      home: Scaffold(
        body: EmoteMenuPanelWidget(
          isActive: true,
          selectedChannel: 'ch',
          onEmoteSelected: (_) {},
          onClose: () {},
          emoteManager: manager,
          scrollController: ScrollController(),
          sheetCtrl: DraggableScrollableController(),
          emoteMaxFraction: 0.8,
        ),
      ),
    );
  }

  testWidgets('a 7TV insert only builds cells at and below the change', (
    WidgetTester tester,
  ) async {
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      removeCachedFile: (url) async {},
    );
    manager.updateSevenTvEmotes('ch', added: [
      sevenTv('a', 'Alpha'),
      sevenTv('c', 'Charlie'),
      sevenTv('d', 'Delta'),
    ]);

    await tester.pumpWidget(wrap(manager));
    await tester.tap(find.text('Channel'));
    await tester.pumpAndSettle();

    final alphaElement = tester.element(find.byKey(const ValueKey('a')));
    final deltaElement = tester.element(find.byKey(const ValueKey('d')));

    // Insert between Alpha and Charlie: Alpha stays in place (identical
    // element), Delta shifts down but keeps its element via keyed
    // reconciliation, and only the new cell is built.
    manager.updateSevenTvEmotes('ch', added: [sevenTv('b', 'Bravo')]);
    await tester.pumpAndSettle();

    expect(
      tester.element(find.byKey(const ValueKey('a'))),
      same(alphaElement),
    );
    expect(
      tester.element(find.byKey(const ValueKey('d'))),
      same(deltaElement),
    );
    expect(find.byKey(const ValueKey('b')), findsOneWidget);
  });

  testWidgets('a 7TV removal reuses the elements below the change', (
    WidgetTester tester,
  ) async {
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      removeCachedFile: (url) async {},
    );
    manager.updateSevenTvEmotes('ch', added: [
      sevenTv('a', 'Alpha'),
      sevenTv('b', 'Bravo'),
      sevenTv('d', 'Delta'),
    ]);

    await tester.pumpWidget(wrap(manager));
    await tester.tap(find.text('Channel'));
    await tester.pumpAndSettle();

    final alphaElement = tester.element(find.byKey(const ValueKey('a')));
    final deltaElement = tester.element(find.byKey(const ValueKey('d')));

    manager.updateSevenTvEmotes('ch', removedIds: ['b']);
    await tester.pumpAndSettle();

    expect(
      tester.element(find.byKey(const ValueKey('a'))),
      same(alphaElement),
    );
    expect(
      tester.element(find.byKey(const ValueKey('d'))),
      same(deltaElement),
    );
    expect(find.byKey(const ValueKey('b')), findsNothing);
  });
}
