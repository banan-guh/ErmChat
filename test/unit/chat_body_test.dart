import 'package:ermchat/widgets/chat_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('collapseChromeForKeyboard', () {
    test('keeps chrome when the keyboard is closed', () {
      expect(collapseChromeForKeyboard(keyboardH: 0, maxHeight: 100), isFalse);
    });

    test('keeps chrome when room is plentiful', () {
      expect(
        collapseChromeForKeyboard(
          keyboardH: 300,
          maxHeight: kKeyboardChromeCollapseBelowHeight + 1,
        ),
        isFalse,
      );
    });

    test('collapses chrome when the keyboard starves the chat', () {
      expect(
        collapseChromeForKeyboard(
          keyboardH: 300,
          maxHeight: kKeyboardChromeCollapseBelowHeight - 1,
        ),
        isTrue,
      );
    });

    test('keeps chrome exactly at the threshold', () {
      expect(
        collapseChromeForKeyboard(
          keyboardH: 300,
          maxHeight: kKeyboardChromeCollapseBelowHeight,
        ),
        isFalse,
      );
    });
  });
}
