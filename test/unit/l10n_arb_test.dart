import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Placeholder names in an ICU message: `{count}`, `{count, plural, ...}`.
Set<String> _placeholders(String message) => {
  for (final m in RegExp(r'\{(\w+)\s*[,}]').allMatches(message)) m.group(1)!,
};

void main() {
  test('translations keep the English keys and placeholders', () {
    final dir = Directory('lib/l10n');
    Map<String, dynamic> read(File f) =>
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final en = read(File('${dir.path}/app_en.arb'));
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.arb') && !f.path.endsWith('_en.arb'),
    );
    for (final file in files) {
      final arb = read(file);
      for (final entry in arb.entries) {
        if (entry.key.startsWith('@')) continue;
        final source = en[entry.key];
        expect(source, isA<String>(), reason: '${file.path}: ${entry.key}');
        expect(
          _placeholders(entry.value as String),
          _placeholders(source as String),
          reason: '${file.path}: ${entry.key} lost or renamed a placeholder',
        );
      }
    }
  });
  test('every English key is referenced from lib', () {
    final en =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final source = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        // The generated l10n classes name every key; only callers count.
        .where((f) => f.path.endsWith('.dart') && !f.path.contains('l10n/app_'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    final unused = [
      for (final key in en.keys)
        if (!key.startsWith('@') && !RegExp('\\b$key\\b').hasMatch(source)) key,
    ];
    expect(unused, isEmpty, reason: 'ARB keys no code reads');
  });
}
