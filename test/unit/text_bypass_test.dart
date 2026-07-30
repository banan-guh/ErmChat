import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/util/text_bypass.dart';

const _invisibleChar = '\u034F';

void main() {
  group('bypassTextDuplicate', () {
    test('doubles first space in multi-word text', () {
      final result = bypassTextDuplicate('hello world');
      expect(result, 'hello  world');
    });

    test('doubles first space when there are multiple spaces', () {
      final result = bypassTextDuplicate('foo bar baz');
      expect(result, 'foo  bar baz');
    });

    test('appends suffix to single-word text', () {
      final result = bypassTextDuplicate('hello');
      expect(result, 'hello $_invisibleChar');
    });

    test('skips leading slash and doubles first space', () {
      final result = bypassTextDuplicate('/ban user');
      expect(result, '/ban  user');
    });

    test('skips leading dot and doubles first space', () {
      final result = bypassTextDuplicate('.timeout user 60');
      expect(result, '.timeout  user 60');
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

    test('handles text with only a command prefix and no args', () {
      final result = bypassTextDuplicate('/');
      expect(result, '/ $_invisibleChar');
    });

    test('handles empty string', () {
      final result = bypassTextDuplicate('');
      expect(result, ' $_invisibleChar');
    });

    test('text with only spaces doubles first space', () {
      final result = bypassTextDuplicate(' ');
      expect(result, '  ');
    });
  });

  group('normalizeForReconciliation', () {
    test('strips invisible char and trailing space', () {
      final result = normalizeForReconciliation('hello $_invisibleChar');
      expect(result, 'hello');
      expect(result.endsWith(' '), false);
    });

    test('collapses doubled spaces to single space', () {
      final result = normalizeForReconciliation('hello  world');
      expect(result, 'hello world');
    });

    test('collapses multiple spaces to single space', () {
      final result = normalizeForReconciliation('hello   world');
      expect(result, 'hello world');
    });

    test('leaves normal text unchanged', () {
      final result = normalizeForReconciliation('hello world');
      expect(result, 'hello world');
    });

    test('handles empty string', () {
      final result = normalizeForReconciliation('');
      expect(result, '');
    });

    test('handles text with only invisible char', () {
      final result = normalizeForReconciliation(_invisibleChar);
      expect(result, '');
    });
  });
}
