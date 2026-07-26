import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/suggestion.dart';

void main() {
  group('getCurrentWord', () {
    test('returns full text when cursor at end and no spaces', () {
      final word = getCurrentWord('hello', 5);
      expect(word.start, 0);
      expect(word.end, 5);
      expect(word.text, 'hello');
    });

    test('returns empty when text is empty', () {
      final word = getCurrentWord('', 0);
      expect(word.start, 0);
      expect(word.end, 0);
      expect(word.text, '');
    });

    test('returns word at cursor from middle of text', () {
      final word = getCurrentWord('hello world foo', 8);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns word at cursor start of word', () {
      final word = getCurrentWord('hello world', 6);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns word at cursor end of word', () {
      final word = getCurrentWord('hello world', 11);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns first word when cursor at start', () {
      final word = getCurrentWord('hello world', 0);
      expect(word.start, 0);
      expect(word.end, 5);
      expect(word.text, 'hello');
    });

    test('clamps cursor beyond text length', () {
      final word = getCurrentWord('hi', 10);
      expect(word.start, 0);
      expect(word.end, 2);
      expect(word.text, 'hi');
    });

    test('handles multiple spaces between words', () {
      final word = getCurrentWord('hello  world', 9);
      expect(word.start, 7);
      expect(word.end, 12);
      expect(word.text, 'world');
    });
  });

  group('replaceCurrentWord', () {
    test('replaces single word', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 8);
      replaceCurrentWord(controller, 'foo');
      expect(controller.text, 'hello foo ');
      expect(controller.selection.baseOffset, 10);
    });

    test('replaces word at start of text', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 2);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi world');
      expect(controller.selection.baseOffset, 2);
    });

    test('replaces word at end of text', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 11);
      replaceCurrentWord(controller, 'earth');
      expect(controller.text, 'hello earth ');
      expect(controller.selection.baseOffset, 12);
    });

    test('replaces only word in text', () {
      final controller = TextEditingController(text: 'hello');
      controller.selection = TextSelection.collapsed(offset: 5);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi ');
      expect(controller.selection.baseOffset, 3);
    });

    test('handles empty text', () {
      final controller = TextEditingController(text: '');
      controller.selection = TextSelection.collapsed(offset: 0);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi ');
      expect(controller.selection.baseOffset, 3);
    });
  });
}
