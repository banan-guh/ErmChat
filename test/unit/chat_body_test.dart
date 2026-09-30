import 'package:ermchat/chrome/stream_layout.dart';
import 'package:ermchat/widgets/chat_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('collapseChromeForKeyboard', () {
    test('collapses only when an open keyboard starves the chat', () {
      const threshold = kKeyboardChromeCollapseBelowHeight;
      const cases = [
        (0.0, 100.0, false),
        (300.0, threshold + 1, false),
        (300.0, threshold, false),
        (300.0, threshold - 1, true),
      ];
      for (final (keyboardH, maxHeight, expected) in cases) {
        expect(
          collapseChromeForKeyboard(keyboardH: keyboardH, maxHeight: maxHeight),
          expected,
          reason: 'keyboard $keyboardH, height $maxHeight',
        );
      }
    });
  });

  group('shouldShowStreamVideo', () {
    test('shows when the keyboard is closed', () {
      expect(
        shouldShowStreamVideo(
          maxWidth: 400,
          maxHeight: 100,
          keyboardH: 0,
          inputH: 56,
          chatFontSize: 14,
        ),
        isTrue,
      );
    });

    test('shows when 9 chat lines remain', () {
      // streamH 225 + input 56 + 9 lines at 14px = 407.
      expect(
        shouldShowStreamVideo(
          maxWidth: 400,
          maxHeight: 407,
          keyboardH: 300,
          inputH: 56,
          chatFontSize: 14,
        ),
        isTrue,
      );
    });

    test('hides when under 9 chat lines remain', () {
      expect(
        shouldShowStreamVideo(
          maxWidth: 400,
          maxHeight: 406.9,
          keyboardH: 300,
          inputH: 56,
          chatFontSize: 14,
        ),
        isFalse,
      );
    });

    test('taller input hides sooner', () {
      expect(
        shouldShowStreamVideo(
          maxWidth: 400,
          maxHeight: 500,
          keyboardH: 300,
          inputH: 200,
          chatFontSize: 14,
        ),
        isFalse,
      );
      expect(
        shouldShowStreamVideo(
          maxWidth: 400,
          maxHeight: 500,
          keyboardH: 300,
          inputH: 0,
          chatFontSize: 14,
        ),
        isTrue,
      );
    });
  });
}
