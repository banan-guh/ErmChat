import 'package:ermchat/screens/settings/battery_settings_screen.dart';
import 'package:ermchat/screens/settings/chat_settings_screen.dart';
import 'package:ermchat/screens/settings/custom_layout_screen.dart';
import 'package:ermchat/screens/settings/customization_screen.dart';
import 'package:ermchat/screens/settings/data_settings_screen.dart';
import 'package:ermchat/screens/settings/emotes_settings_screen.dart';
import 'package:ermchat/screens/settings/history_settings_screen.dart';
import 'package:ermchat/screens/settings/inline_embeds_screen.dart';
import 'package:ermchat/screens/settings/pings_screen.dart';
import 'package:ermchat/screens/settings/settings_search.dart';
import 'package:ermchat/screens/settings/tools_settings_screen.dart';
import 'package:ermchat/screens/settings/tts_settings_screen.dart';
import 'package:ermchat/screens/settings/uploader_settings_screen.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/emote_images.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/ping_manager.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/util/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pages whose rows are declared in [Settings.all]; whole-page entries
/// (Channels, Account, About) have nothing to anchor.
Widget? _page(SettingsPageId page) => switch (page) {
  SettingsPageId.appearance => const CustomizationScreen(),
  SettingsPageId.customLayout => const CustomLayoutScreen(),
  SettingsPageId.chat => ChatSettingsScreen(twitchAuth: TwitchAuth()),
  SettingsPageId.inlineEmbeds => const InlineEmbedsScreen(),
  SettingsPageId.highlights => const PingsScreen(),
  SettingsPageId.emotes => EmotesSettingsScreen(
    mobileNotifier: ValueNotifier(false),
    emoteManager: EmoteManager(fetchStagger: Duration.zero),
  ),
  SettingsPageId.data => DataSettingsScreen(
    mobileNotifier: ValueNotifier(false),
    images: EmoteImages(),
  ),
  SettingsPageId.history => const HistorySettingsScreen(),
  SettingsPageId.battery => const BatterySettingsScreen(),
  SettingsPageId.tools => ToolsSettingsScreen(
    analyticsService: AnalyticsService(),
    channels: const [],
    images: EmoteImages(),
  ),
  SettingsPageId.tts => const TtsSettingsScreen(),
  SettingsPageId.uploader => const UploaderSettingsScreen(),
  SettingsPageId.channels ||
  SettingsPageId.account ||
  SettingsPageId.about ||
  SettingsPageId.language => null,
};

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(key: UniqueKey(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PingManager.instance.load();
  });

  // The registry is what search and the anchors both key on.
  test('every registered row has a title and a known page', () {
    expect(
      Settings.all.map((s) => s.id).toSet().length,
      Settings.all.length,
      reason: 'ids key the titles and the anchors, so they are unique',
    );
    for (final s in Settings.all) {
      expect(hasTitleEntry(s.id), isTrue, reason: '${s.key} has no title');
      expect(
        SettingsPageId.values.map((p) => p.name),
        contains(s.page),
        reason: '${s.id} names an unknown page',
      );
    }
    for (final r in SettingsRow.all) {
      expect(hasTitleEntry(r.id), isTrue, reason: '${r.id} has no title');
    }
  });

  // A renamed, moved or deleted tile would leave search pointing at nothing.
  testWidgets('every searchable row is on the page search opens', (
    tester,
  ) async {
    // Tall enough that lazy lists build every row.
    tester.view.physicalSize = const Size(1000, 12000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final page in SettingsPageId.values) {
      final widget = _page(page);
      // Aggregate pages show their mirrors' own tiles, so those count too.
      final settings = [
        for (final s in Settings.all)
          if (s.anchored &&
              gateOpen(s.gate) &&
              (s.page == page.name || s.mirrors.contains(page.name)))
            s,
      ];
      final rows = [
        for (final r in SettingsRow.all)
          if (r.anchored && r.page == page) r,
      ];
      if (widget == null) {
        expect(settings, isEmpty, reason: '$page has no test page');
        expect(rows, isEmpty, reason: '$page has no test page');
        continue;
      }
      await _pump(tester, widget);
      for (final s in settings) {
        expect(
          find.byKey(ValueKey('setting:${s.id}')),
          findsOneWidget,
          reason: '${s.id} missing from $page',
        );
        expect(
          find.textContaining(s.enTitle, skipOffstage: false),
          findsWidgets,
          reason: '${s.id} label drifted on $page',
        );
      }
      for (final r in rows) {
        expect(
          find.byKey(ValueKey('setting:${r.id}')),
          findsOneWidget,
          reason: '${r.id} missing from $page',
        );
        expect(
          find.textContaining(r.enTitle, skipOffstage: false),
          findsWidgets,
          reason: '${r.id} label drifted on $page',
        );
      }
    }
  });

  // A switch added without a setting would ship unsearchable.
  testWidgets('every switch tile on a searchable page is anchored', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 12000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var seen = 0;
    for (final page in SettingsPageId.values) {
      final widget = _page(page);
      if (widget == null) continue;
      await _pump(tester, widget);
      final loose = find.byWidgetPredicate(
        (w) => w is SwitchListTile,
        skipOffstage: false,
      );
      for (final e in loose.evaluate()) {
        seen++;
        expect(
          e.findAncestorWidgetOfExactType<SettingAnchor>(),
          isNotNull,
          reason: 'a switch on $page has no SettingAnchor',
        );
      }
    }
    expect(seen, greaterThan(0), reason: 'switches exist to check');
  });

  testWidgets('a result far down an unbuilt list scrolls into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The last row of Appearance: not built until the list pages down.
    await _pump(
      tester,
      const SettingsTarget(
        id: 'fast_channel_swipe',
        child: CustomizationScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('setting:fast_channel_swipe'));
    expect(row, findsOneWidget);
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
  });
}
