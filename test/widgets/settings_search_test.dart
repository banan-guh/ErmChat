import 'package:ermchat/screens/settings/chat_settings_screen.dart';
import 'package:ermchat/screens/settings/custom_layout_screen.dart';
import 'package:ermchat/screens/settings/customization_screen.dart';
import 'package:ermchat/screens/settings/emotes_settings_screen.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pages whose settings are declared in [Setting]; whole-page entries
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

  // A renamed, moved or deleted tile would leave search pointing at nothing.
  testWidgets('every searchable setting is on the page search opens', (
    tester,
  ) async {
    // Tall enough that lazy lists build every row.
    tester.view.physicalSize = const Size(1000, 12000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final page in SettingsPageId.values) {
      final widget = _page(page);
      final expected = Setting.available
          .where((s) => s.page == page && s.anchored)
          .toList();
      if (widget == null) {
        expect(expected, isEmpty, reason: '$page has no test page');
        continue;
      }
      await _pump(tester, widget);
      for (final setting in expected) {
        expect(
          find.byKey(ValueKey('setting:${setting.id}')),
          findsOneWidget,
          reason: '${setting.id} missing from $page',
        );
        expect(
          find.textContaining(setting.title, skipOffstage: false),
          findsWidgets,
          reason: '${setting.id} label drifted on $page',
        );
      }
    }
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
        target: Setting.fastChannelSwipe,
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
