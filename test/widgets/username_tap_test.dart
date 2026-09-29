import 'package:ermchat/util/mention.dart';
import 'package:flutter/rendering.dart';
import 'widget_test_harness.dart';

// The name zone is hit-tested on the row: left of the name (timestamp,
// badges), the name, and a margin past it. Double tap on it copies the name;
// elsewhere it still copies the message.
void main() {
  final taps = <String>[];

  Future<void> pumpTile(
    WidgetTester tester, {
    bool doubleTapUser = true,
  }) async {
    taps.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ChatMessageTile(
              message: TwitchMessage(
                login: 'alice',
                text: 'hi there friend',
                channel: 'somechannel',
                messageId: 'm1',
              ),
              channel: 'somechannel',
              surface: Colors.white,
              textScale: 1.0,
              showTimestamp: false,
              buildBadgeSpans: (_, _, {double badgeScale = 1.0}) => const [],
              buildMessageSpans:
                  (_, _, _, {colored = false, textScale = 1.0, onImageTap}) =>
                      <InlineSpan>[const TextSpan(text: 'hi there friend')],
              bodyIsCached: (_, _) => false,
              onTapUser: (login, _) => taps.add('user:$login'),
              onDoubleTapUser: doubleTapUser ? () => taps.add('copy') : null,
              onDoubleTap: () => taps.add('message'),
              onLongPress: () {},
            ),
          ),
        ),
      ),
    );
  }

  // Global rect of "alice: " in the row paragraph.
  Rect nameRect(WidgetTester tester) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText).first,
    );
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 7),
        )
        .first
        .toRect();
    return box.shift(paragraph.localToGlobal(Offset.zero));
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 350));

  testWidgets('a tap left of, on, or just past the name opens the user', (
    tester,
  ) async {
    await pumpTile(tester);
    final name = nameRect(tester);
    for (final x in [2.0, name.center.dx, name.right + 8]) {
      await tester.tapAt(Offset(x, name.center.dy));
      await settle(tester);
    }
    expect(taps, ['user:alice', 'user:alice', 'user:alice']);
  });

  testWidgets('a tap in the body text does not open the user', (tester) async {
    await pumpTile(tester);
    final name = nameRect(tester);
    await tester.tapAt(Offset(name.right + 60, name.center.dy));
    await settle(tester);
    expect(taps, isEmpty);
  });

  testWidgets('double tap on the name copies it, not the message', (
    tester,
  ) async {
    await pumpTile(tester);
    final at = nameRect(tester).center;
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await settle(tester);
    expect(taps, ['copy']);
  });

  testWidgets('double tap on the body still copies the message', (
    tester,
  ) async {
    await pumpTile(tester);
    final name = nameRect(tester);
    final at = Offset(name.right + 60, name.center.dy);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await settle(tester);
    expect(taps, ['message']);
  });

  testWidgets('without double tap copy the name opens at once', (tester) async {
    await pumpTile(tester, doubleTapUser: false);
    await tester.tapAt(nameRect(tester).center);
    await tester.pump();
    expect(taps, ['user:alice']);
  });

  test('formatMention follows the mention format pref', () {
    expect(formatMention('@name', 'Alice'), '@Alice ');
    expect(formatMention('@name,', 'Alice'), '@Alice, ');
    expect(formatMention('name', 'Alice'), 'Alice ');
    expect(formatMention('name,', 'Alice'), 'Alice, ');
  });
}
