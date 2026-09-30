import 'package:ermchat/util/chat_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cleanChatText', () {
    test('drops duplicate-bypass marks and collapses the gap', () {
      // Real message: two spaces then a CGJ from a 7TV dedupe suffix.
      expect(cleanChatText('Bussin eat  ͏'), 'Bussin eat ');
      expect(cleanChatText('hi \u{E0000}'), 'hi ');
    });

    test('drops zero-width spaces and turns blank lookalikes into spaces', () {
      expect(cleanChatText('a​b⁠c﻿'), 'abc');
      expect(cleanChatText('a  b'), 'a b');
      expect(cleanChatText('a　bㅤc'), 'a b c');
      expect(cleanChatText('a   b'), 'a b');
    });

    test('keeps emoji intact', () {
      const family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
      const heart = '❤️';
      const scotland =
          '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}';
      const keycap = '1️⃣';
      for (final emoji in [family, heart, scotland, keycap]) {
        expect(cleanChatText('hey $emoji  ok'), 'hey $emoji ok');
      }
    });

    test('keeps braille art and clean text as is', () {
      const art = '⠀⠀⣿⠀';
      expect(cleanChatText(art), art);
      const text = 'nothing to clean here';
      expect(identical(cleanChatText(text), text), isTrue);
    });
  });

  test('copyableChatText trims what cleaning leaves at the ends', () {
    expect(copyableChatText('  Bussin eat  ͏'), 'Bussin eat');
  });
}
