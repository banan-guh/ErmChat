import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/util/text_bypass.dart';

const _invisibleChar = '\u034F';

void main() {
  group('bypassTextDuplicate', () {
    test('doubles first space in multi-word text', () {
      final result = bypassTextDuplicate('hello world');
      expect(result, 'hello  world');
    });

    test(
      'chaining: repeated bypass on single-word keeps producing unique strings',
      () {
        var wire = 'hello';
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello $_invisibleChar');
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello  $_invisibleChar');
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello   $_invisibleChar');
      },
    );

    test(
      'chaining: repeated bypass on multi-word keeps producing unique strings',
      () {
        var wire = 'hello world';
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello  world');
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello   world');
        wire = bypassTextDuplicate(wire);
        expect(wire, 'hello    world');
      },
    );

    test('handles empty string', () {
      final result = bypassTextDuplicate('');
      expect(result, ' $_invisibleChar');
    });

    test('text with only spaces doubles first space', () {
      final result = bypassTextDuplicate(' ');
      expect(result, '  ');
    });
  });
}
