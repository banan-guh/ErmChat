import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ermchat/main.dart';

void main() {
  group('buildDarkTheme', () {
    test('non-true dark uses a neutral dark surface, not pure black', () {
      final scheme = buildDarkTheme(trueDark: false).colorScheme;
      expect(scheme.surface, isNot(Colors.black));
      expect(scheme.background, isNot(Colors.black));
      expect(
        scheme.surfaceContainer,
        const Color(0xFF222222),
        reason: 'neutral grey chrome shared by both variants',
      );
    });

    test('true dark pins surface and background to pure black', () {
      final scheme = buildDarkTheme(trueDark: true).colorScheme;
      expect(scheme.surface, Colors.black);
      expect(scheme.background, Colors.black);
      expect(scheme.onSurface, Colors.white);
      expect(scheme.onBackground, Colors.white);
      expect(
        scheme.surfaceContainer,
        const Color(0xFF222222),
        reason: 'chrome stays neutral grey in true dark too',
      );
    });
  });
}
