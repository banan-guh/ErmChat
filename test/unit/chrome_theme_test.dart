import 'package:ermchat/util/chrome_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every preset survives the paste format, short enough to paste', () {
    final longName = 'x' * ChromeThemeSpec.maxNameLength;
    for (final t in ChromeTheme.values) {
      for (final spec in [t.spec, t.spec.copyWith(name: longName)]) {
        final line = spec.encode();
        expect(ChromeThemeSpec.decode(line), spec, reason: '${t.name}: $line');
        // Phone clipboards cut long pastes; a theme must never come close.
        expect(line.length, lessThan(200), reason: line);
      }
    }
    final named = ChromeThemeSpec.blank.copyWith(name: 'a;b=c %d');
    expect(ChromeThemeSpec.decode(named.encode()), named);
  });

  test('a mangled line decodes to null or something usable', () {
    for (final bad in ['', 'hello', 'ermchat-theme:1', 'ermchat-theme:2;h=s']) {
      expect(ChromeThemeSpec.decode(bad), isNull, reason: bad);
    }
    // Unknown letters drop; an action placed twice keeps its first place.
    final spec = ChromeThemeSpec.decode('ermchat-theme:1;h=s;t=sZs;r=s;s=q')!;
    expect(spec.stripActions, [ChromeAction.settings]);
    expect(spec.rowStart, isEmpty);
    expect(spec.send, SendPlace.field);
    expect(spec.reachesSettings, isTrue);
  });
}
