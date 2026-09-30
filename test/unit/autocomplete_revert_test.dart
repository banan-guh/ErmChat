import 'package:ermchat/composer/autocomplete_revert.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _value(String text, int offset) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: offset),
);

void main() {
  group('AutocompleteRevertFormatter', () {
    test('restores the typed token on a single backspace after the region', () {
      final cases = [
        ('Kappa ', 'Kappa ', 6, 'Kappa', 5, 'Kapp'),
        ('Kappa', 'Kappa world', 5, 'Kapp world', 4, 'Kapp world'),
      ];
      for (final (replacement, oldText, oldAt, newText, newAt, want) in cases) {
        final formatter = AutocompleteRevertFormatter()
          ..markReplaced(start: 0, original: 'Kapp', replacement: replacement);
        final result = formatter.formatEditUpdate(
          _value(oldText, oldAt),
          _value(newText, newAt),
        );
        expect(result.text, want, reason: oldText);
        expect(result.selection.baseOffset, 4);
      }
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

    test('other edits pass through untouched', () {
      const selection = TextEditingValue(
        text: 'Kappa',
        selection: TextSelection(baseOffset: 1, extentOffset: 4),
      );
      final cases = <(String, bool, TextEditingValue, TextEditingValue)>[
        ('no mark', false, _value('hello', 5), _value('hell', 4)),
        ('delete outside', true, _value('Kappa ', 6), _value('appa ', 0)),
        ('multi-char deletion', true, _value('Kappa ', 6), _value('Kapp', 4)),
        ('non-collapsed selection', true, _value('Kappa ', 6), selection),
      ];
      for (final (name, marked, oldValue, newValue) in cases) {
        final formatter = AutocompleteRevertFormatter();
        if (marked) {
          formatter.markReplaced(
            start: 0,
            original: 'Kapp',
            replacement: 'Kappa ',
          );
        }
        expect(
          formatter.formatEditUpdate(oldValue, newValue),
          newValue,
          reason: name,
        );
      }
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
