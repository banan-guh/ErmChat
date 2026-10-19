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
    final shapes = <(String, ChromeThemeSpec)>[
      ('emote and send in the field', ChromeThemeSpec.blank),
      (
        'send in the column, emote in the row',
        ChromeThemeSpec.blank.copyWith(fieldStart: [], fieldEnd: []),
      ),
      (
        'send in the row',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [],
          fieldEnd: [],
          sendAside: SendPlace.row,
        ),
      ),
      (
        'both on one side with an action ahead',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [FieldItem.action(ChromeAction.threads), FieldItem.send],
          fieldEnd: [],
        ),
      ),
      ('compact', ChromeThemeSpec.blank.copyWith(compact: true)),
    ];
    for (final (name, spec) in shapes) {
      expect(ChromeThemeSpec.decode(spec.encode()), spec, reason: name);
    }
  });

  test('old lines map emote and send onto the field row', () {
    // Lines saved before the field row carry s= and maybe e=, never c=. An
    // island with a row and send out of it was compact on a phone, which
    // kept both buttons in the field.
    final cases =
        <(String, String, List<FieldItem>, List<FieldItem>, SendPlace, bool)>[
          (
            'send in field, no row',
            'ermchat-theme:1;h=s;t=sv;s=f',
            [FieldItem.emote],
            [FieldItem.send],
            SendPlace.field,
            false,
          ),
          (
            'send in field, emote in row',
            'ermchat-theme:1;h=s;t=sv;s=f;e=r',
            [FieldItem.emote],
            [FieldItem.send],
            SendPlace.field,
            true,
          ),
          (
            'send in column',
            'ermchat-theme:1;h=s;t=sv;s=c',
            [FieldItem.emote],
            [FieldItem.send],
            SendPlace.field,
            true,
          ),
          (
            'unknown emote place follows send',
            'ermchat-theme:1;h=s;t=sv;s=c;e=z',
            [FieldItem.emote],
            [FieldItem.send],
            SendPlace.field,
            true,
          ),
          (
            'send in row kept the row up while typing',
            'ermchat-theme:1;h=s;t=sv;s=r',
            [],
            [],
            SendPlace.row,
            false,
          ),
          (
            'edge to edge never hid its row',
            'ermchat-theme:1;h=s;t=sv;s=c;f=F',
            [],
            [],
            SendPlace.column,
            false,
          ),
          (
            'edge to edge, emote placed in the field',
            'ermchat-theme:1;h=s;t=sv;s=c;e=f;f=F',
            [FieldItem.emote],
            [],
            SendPlace.column,
            false,
          ),
          (
            'row actions make a row',
            'ermchat-theme:1;h=s;t=v;r=s;s=f',
            [FieldItem.emote],
            [FieldItem.send],
            SendPlace.field,
            true,
          ),
        ];
    for (final (name, line, start, end, send, compact) in cases) {
      final spec = ChromeThemeSpec.decode(line)!;
      expect(spec.fieldStart, start, reason: '$name: field start');
      expect(spec.fieldEnd, end, reason: '$name: field end');
      expect(spec.send, send, reason: '$name: send');
      expect(spec.compact, compact, reason: '$name: compact');
    }
  });

  test('the field row holds two buttons, and compact keeps send in it', () {
    final threads = FieldItem.action(ChromeAction.threads);
    final mentions = FieldItem.action(ChromeAction.mentions);
    final cases = <(String, ChromeThemeSpec, List<FieldItem>, List<FieldItem>)>[
      (
        'three cut from the end, send falls out of the field',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [mentions, FieldItem.emote],
          fieldEnd: [FieldItem.send],
        ),
        [mentions, FieldItem.emote],
        [],
      ),
      (
        'both on one side is fine',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [],
          fieldEnd: [threads, FieldItem.send],
        ),
        [],
        [threads, FieldItem.send],
      ),
      (
        'a cut action lands at the row end',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [FieldItem.emote],
          fieldEnd: [threads, mentions],
        ),
        [FieldItem.emote],
        [threads],
      ),
      (
        'compact moves a row send to the field end',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [],
          fieldEnd: [],
          sendAside: SendPlace.row,
          compact: true,
        ),
        [],
        [FieldItem.send],
      ),
      (
        // Shipped bug: a side send stayed out of the field under compact,
        // stranded beside the collapsed row.
        'compact pulls a side send into the field end',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [],
          fieldEnd: [],
          sendAside: SendPlace.column,
          compact: true,
        ),
        [],
        [FieldItem.send],
      ),
      (
        'compact makes room for send by cutting the last button',
        ChromeThemeSpec.blank.copyWith(
          fieldStart: [threads],
          fieldEnd: [FieldItem.emote],
          sendAside: SendPlace.row,
          compact: true,
        ),
        [threads],
        [FieldItem.send],
      ),
    ];
    for (final (name, spec, start, end) in cases) {
      final fitted = spec.fitted();
      expect(fitted.fieldStart, start, reason: '$name: start');
      expect(fitted.fieldEnd, end, reason: '$name: end');
      expect(ChromeThemeSpec.decode(spec.encode())!.fieldItems, [
        ...start,
        ...end,
      ], reason: '$name: a pasted line fits the same way');
    }
    expect(
      ChromeThemeSpec.blank
          .copyWith(fieldStart: [threads], fieldEnd: [FieldItem.send])
          .place(ChromeAction.mentions, LayoutSlot.fieldEnd)
          .fieldItems,
      [threads, FieldItem.send],
      reason: 'a full field refuses another action',
    );
    final tight = ChromeThemeSpec.blank.copyWith(compact: true);
    expect(tight.canPlacePart(ComposerPart.send, PartPlace.row), isFalse);
    expect(tight.canPlacePart(ComposerPart.send, PartPlace.column), isFalse);
    expect(tight.canPlacePart(ComposerPart.emote, PartPlace.row), isTrue);
    for (final style in [ComposerStyle.flush, ComposerStyle.classic]) {
      expect(
        tight.copyWith(composer: style).normalized().compact,
        isFalse,
        reason: '$style clears compact',
      );
    }
    expect(
      ChromeThemeSpec.decode(
        tight.copyWith(composer: ComposerStyle.flush).encode(),
      )!.compact,
      isFalse,
      reason: 'a pasted compact edge-to-edge line is not compact',
    );
    expect(ChromeTheme.ermchat.spec.compact, isFalse);
    expect(ChromeTheme.dankchat3.spec.compact, isFalse);
    expect(ChromeTheme.dankchat4.spec.compact, isFalse);
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
    // %FF is not valid UTF-8, so Uri.decodeComponent throws on a crafted
    // paste; the name decodes empty.
    final badName = ChromeThemeSpec.decode('ermchat-theme:1;n=%FF;h=s;t=s')!;
    expect(badName.name, isEmpty);
    expect(badName.header, HeaderStyle.strip);
  });

  test('a theme is usable only with settings and a view path', () {
    const settingsOnly = ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.settings],
    );
    final cases = <(String, ChromeThemeSpec, bool)>[
      ('no view menu or overflow', settingsOnly, false),
      (
        'settings and view menu',
        settingsOnly.copyWith(
          stripActions: [ChromeAction.settings, ChromeAction.viewMenu],
        ),
        true,
      ),
      (
        'settings and overflow',
        settingsOnly.copyWith(
          stripActions: [ChromeAction.settings, ChromeAction.overflow],
        ),
        true,
      ),
      (
        'settings unreachable',
        const ChromeThemeSpec(
          header: HeaderStyle.strip,
          stripActions: [ChromeAction.viewMenu],
        ),
        false,
      ),
      (
        'locked theme with no actions',
        const ChromeThemeSpec(header: HeaderStyle.strip, stripActions: []),
        false,
      ),
      ('blank', ChromeThemeSpec.blank, true),
      for (final t in ChromeTheme.values) ('preset ${t.name}', t.spec, true),
    ];
    for (final (name, spec, usable) in cases) {
      expect(spec.isUsable, usable, reason: name);
      final fixed = spec.normalized();
      expect(
        fixed.isUsable,
        isTrue,
        reason: '$name: normalizing left it locked',
      );
      if (usable) {
        expect(
          fixed,
          spec,
          reason: '$name: normalizing changed a usable theme',
        );
      }
      if (spec.stripActions.isEmpty) {
        expect(fixed.places(ChromeAction.settings), isTrue, reason: name);
        expect(fixed.places(ChromeAction.viewMenu), isTrue, reason: name);
      }
    }
  });

  test('place moves an action to one spot, in order', () {
    const a = ChromeAction.mentions;
    const spec = ChromeThemeSpec(
      header: HeaderStyle.appBar,
      stripActions: [ChromeAction.settings, ChromeAction.viewMenu, a],
      rowStart: [ChromeAction.threads],
    );
    final cases =
        <(String, LayoutSlot?, int?, ChromeAction, List<List<ChromeAction>>)>[
          // strip, appBar, rowStart, rowEnd after the move.
          (
            'to another slot, end',
            LayoutSlot.rowEnd,
            null,
            a,
            [
              [ChromeAction.settings, ChromeAction.viewMenu],
              [],
              [ChromeAction.threads],
              [a],
            ],
          ),
          (
            'before an existing one',
            LayoutSlot.rowStart,
            0,
            a,
            [
              [ChromeAction.settings, ChromeAction.viewMenu],
              [],
              [a, ChromeAction.threads],
              [],
            ],
          ),
          (
            'forward in its own slot lands where dropped',
            LayoutSlot.strip,
            3,
            ChromeAction.settings,
            [
              [ChromeAction.viewMenu, a, ChromeAction.settings],
              [],
              [ChromeAction.threads],
              [],
            ],
          ),
          (
            'removed',
            null,
            null,
            ChromeAction.threads,
            [
              [ChromeAction.settings, ChromeAction.viewMenu, a],
              [],
              [],
              [],
            ],
          ),
        ];
    for (final (name, slot, index, action, want) in cases) {
      final got = spec.place(action, slot, index: index);
      expect(
        [got.stripActions, got.appBarActions, got.rowStart, got.rowEnd],
        want,
        reason: name,
      );
    }
  });

  test('removeBlock keeps settings and a view path reachable', () {
    const strip = ChromeThemeSpec(
      header: HeaderStyle.strip,
      stripActions: [ChromeAction.settings, ChromeAction.viewMenu],
    );
    final viaOverflow = strip.copyWith(
      stripActions: [ChromeAction.viewMenu, ChromeAction.overflow],
    );
    final cases = <(String, ChromeThemeSpec, ChromeAction, LayoutBlock?)>[
      (
        'settings with no menu',
        strip,
        ChromeAction.settings,
        LayoutBlock.settings,
      ),
      (
        'view menu with no overflow',
        strip,
        ChromeAction.viewMenu,
        LayoutBlock.viewPath,
      ),
      (
        'overflow carries settings',
        viaOverflow,
        ChromeAction.overflow,
        LayoutBlock.settings,
      ),
      ('unplaced action', strip, ChromeAction.threads, null),
      (
        'settings behind overflow may go',
        strip.copyWith(
          stripActions: [
            ChromeAction.settings,
            ChromeAction.viewMenu,
            ChromeAction.overflow,
          ],
        ),
        ChromeAction.settings,
        null,
      ),
    ];
    for (final (name, spec, action, block) in cases) {
      expect(spec.removeBlock(action), block, reason: name);
    }
  });

  test('leaving the app bar keeps its actions on the strip', () {
    final spec = ChromeTheme.dankchat3.spec.withHeader(HeaderStyle.bubbles);
    expect(spec.appBarActions, isEmpty);
    expect(spec.stripActions, [
      ChromeAction.viewMenu,
      ChromeAction.join,
      ChromeAction.mentions,
      ChromeAction.overflow,
    ]);
    expect(spec.slots, isNot(contains(LayoutSlot.appBar)));
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
