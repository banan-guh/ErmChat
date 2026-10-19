import 'package:ermchat/util/chrome_theme.dart';
import 'package:ermchat/util/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    // It still needs a view path; normalizing gives it one.
    expect(spec.normalized().isUsable, isTrue);
  });

  test('an invalid UTF-8 name percent decodes to an empty name', () {
    // %FF is not valid UTF-8, so Uri.decodeComponent throws FormatException
    // on a crafted paste.
    final spec = ChromeThemeSpec.decode('ermchat-theme:1;n=%FF;h=s;t=s')!;
    expect(spec.name, isEmpty);
    expect(spec.header, HeaderStyle.strip);
  });

  test('a theme is usable only with settings and a view path', () {
    const settingsOnly = ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.settings],
    );
    expect(settingsOnly.isUsable, isFalse, reason: 'no view menu or overflow');
    expect(
      settingsOnly
          .copyWith(
            stripActions: [ChromeAction.settings, ChromeAction.viewMenu],
          )
          .isUsable,
      isTrue,
    );
    expect(
      settingsOnly
          .copyWith(
            stripActions: [ChromeAction.settings, ChromeAction.overflow],
          )
          .isUsable,
      isTrue,
    );
    const viewOnly = ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.viewMenu],
    );
    expect(viewOnly.isUsable, isFalse, reason: 'settings unreachable');
  });

  test('blank and its presets reach settings and the view menu', () {
    expect(ChromeThemeSpec.blank.isUsable, isTrue);
    expect(ChromeThemeSpec.blank.normalized(), ChromeThemeSpec.blank);
    for (final t in ChromeTheme.values) {
      expect(t.spec.isUsable, isTrue, reason: t.name);
    }
  });

  test('normalizing a locked theme restores both paths', () {
    const locked = ChromeThemeSpec(header: HeaderStyle.strip, stripActions: []);
    final fixed = locked.normalized();
    expect(fixed.isUsable, isTrue);
    expect(fixed.places(ChromeAction.settings), isTrue);
    expect(fixed.places(ChromeAction.viewMenu), isTrue);
  });

  group('chromeTheme pref', () {
    test('a stale custom key repairs to the default preset', () async {
      SharedPreferences.setMockInitialValues({
        'chrome_theme': 'custom:3',
        'chrome_themes_custom': [ChromeThemeSpec.blank.encode()],
      });
      final prefs = await Prefs.load();
      expect(prefs.chromeThemeKey, ChromeTheme.ermchat.name);
      expect(prefs.raw.getString('chrome_theme'), ChromeTheme.ermchat.name);
    });

    test('a stored locked theme reads back usable', () async {
      SharedPreferences.setMockInitialValues({
        'chrome_theme': 'custom:0',
        'chrome_themes_custom': [
          const ChromeThemeSpec(
            header: HeaderStyle.strip,
            stripActions: [],
          ).encode(),
        ],
      });
      final prefs = await Prefs.load();
      expect(prefs.chromeTheme.isUsable, isTrue);
    });
  });
}
