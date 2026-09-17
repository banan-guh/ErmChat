import 'package:ermchat/composer/autocomplete_revert.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _value(String text, int offset) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: offset),
);

void main() {
  group('AutocompleteRevertFormatter', () {
    test('passes through when no mark is set', () {
      final formatter = AutocompleteRevertFormatter();
      final oldValue = _value('hello', 5);
      final newValue = _value('hell', 4);
      expect(formatter.formatEditUpdate(oldValue, newValue), newValue);
    });

    test(
      'restores the typed token on a single backspace at the region end',
      () {
        final formatter = AutocompleteRevertFormatter()
          ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ');
        final result = formatter.formatEditUpdate(
          _value('Kappa ', 6),
          _value('Kappa', 5),
        );
        expect(result.text, 'Kapp');
        expect(result.selection.baseOffset, 4);
      },
    );

    test('restores mid-text when the replacement has no trailing space', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa');
      final result = formatter.formatEditUpdate(
        _value('Kappa world', 5),
        _value('Kapp world', 4),
      );
      expect(result.text, 'Kapp world');
      expect(result.selection.baseOffset, 4);
    });

    test('an unrelated edit clears the mark so it cannot fire later', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ');
      final inserted = formatter.formatEditUpdate(
        _value('Kappa ', 6),
        _value('KappX ', 5),
      );
      expect(inserted.text, 'KappX ');

      final later = formatter.formatEditUpdate(
        _value('KappX ', 6),
        _value('KappX', 5),
      );
      expect(later.text, 'KappX');
    });

    test('deleting outside the region clears the mark', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ');
      final result = formatter.formatEditUpdate(
        _value('Kappa ', 6),
        _value('appa ', 0),
      );
      expect(result.text, 'appa ');
    });

    test('marking again replaces the previous mark', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ')
        ..markReplaced(start: 0, original: 'foo', replacement: 'foobar');
      final result = formatter.formatEditUpdate(
        _value('foobar', 6),
        _value('fooba', 5),
      );
      expect(result.text, 'foo');
      expect(result.selection.baseOffset, 3);
    });

    test('a multi-char deletion does not restore', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ');
      final result = formatter.formatEditUpdate(
        _value('Kappa ', 6),
        _value('Kapp', 4),
      );
      expect(result.text, 'Kapp');
      expect(result.selection.baseOffset, 4);
    });

    test('a non-collapsed selection clears the mark', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ');
      final newValue = const TextEditingValue(
        text: 'Kappa',
        selection: TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(
        formatter.formatEditUpdate(_value('Kappa ', 6), newValue),
        newValue,
      );
    });

    test('clear drops the mark', () {
      final formatter = AutocompleteRevertFormatter()
        ..markReplaced(start: 0, original: 'Kapp', replacement: 'Kappa ')
        ..clear();
      final result = formatter.formatEditUpdate(
        _value('Kappa ', 6),
        _value('Kappa', 5),
      );
      expect(result.text, 'Kappa');
    });
  });
}
