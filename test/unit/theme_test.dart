import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/main.dart';

void main() {
  group('buildDarkTheme', () {
    test('non-true dark keeps M3 surfaces and no overrides', () {
      final scheme = buildDarkTheme(trueDark: false).colorScheme;
      expect(scheme.surface, isNot(Colors.black));
      expect(scheme.surface, isNot(scheme.surfaceContainer));
      expect(
        scheme.surfaceContainer,
        isNot(scheme.surface),
        reason: 'M3 chrome role stays distinct from the body surface',
      );
      final plain = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      );
      expect(scheme.surface, plain.surface);
    });

    test('true dark pins surface and background to pure black', () {
      final scheme = buildDarkTheme(trueDark: true).colorScheme;
      expect(scheme.surface, Colors.black);
      expect(scheme.onSurface, Colors.white);
      expect(
        scheme.surfaceContainer,
        isNot(Colors.black),
        reason: 'chrome stays grey in true dark too',
      );
    });

    test('seed color drives the scheme', () {
      final blue = buildDarkTheme(seedColor: Colors.blue).colorScheme;
      final red = buildDarkTheme(seedColor: Colors.red).colorScheme;
      expect(blue.primary, isNot(red.primary));
    });
  });
}
