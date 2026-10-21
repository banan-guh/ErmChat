// Renders the layout editor to PNGs for eyeballing, not for asserting.
// Run: flutter test test/render/layout_editor_render.dart
// Output: build/render/*.png (1080x2340, real Roboto and Material icons).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ermchat/util/chrome_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../widgets/widget_test_harness.dart';

Future<void> _loadFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Light']) {
    roboto.addFont(
      File('$dir/Roboto-$w.ttf').readAsBytes().then(ByteData.sublistView),
    );
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      File(
        '$dir/MaterialIcons-Regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
  await icons.load();
}

Future<void> _shot(
  WidgetTester tester,
  String name, {
  Duration settle = const Duration(milliseconds: 400),
}) async {
  if (settle > Duration.zero) await tester.pump(settle);
  final element = tester.binding.rootElement!;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('build/render/$name.png');
    await out.create(recursive: true);
    await out.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    WidgetsApp.debugAllowBannerOverride = false;
    HomeScreen.disableJoinSpinner = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
    PackageInfo.setMockInitialValues(
      appName: 'ermchat',
      packageName: 'ermchat',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<FakeIrcReadService> boot(
    WidgetTester tester,
    Map<String, Object> prefs,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(top: 96, bottom: 63);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'access_token': 'test_token',
      'themeMode': 'dark',
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({
      'accounts': '[{"login":"me","user_id":"42","access_token":"test_token"}]',
      'active_login': 'me',
    });
    final irc = FakeIrcService();
    final read = FakeIrcReadService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        recentMessagesService: FakeRecentMessagesService(),
        ircService: irc,
        ircReadService: read,
      ),
    );
    await tester.pump();
    for (final channel in ['vedal987', 'camila']) {
      await tester.tap(find.byTooltip('Join channel').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, channel);
      await tester.tap(find.text('Join', skipOffstage: false));
      await tester.pumpAndSettle();
      irc.triggerConnect();
      read.triggerConnect();
      irc.triggerJoin(channel);
      read.triggerJoin(channel);
      await tester.pump(const Duration(milliseconds: 600));
    }
    const lines = [
      ('Mossbeard', '#E05A9B', 'that was so clean'),
      ('pixelwren', '#4FB3FF', 'what game is this?'),
      ('Tallgrass', '#7CD67C', 'no way she hits that first try'),
      ('quietfox', '#F2A93B', 'LMAO'),
      ('Embervale', '#B98CFF', 'chat is moving fast today'),
      ('Mossbeard', '#E05A9B', '@pixelwren it says in the title'),
      ('nightkite', '#FF6F61', 'gg'),
      ('Driftwood', '#5FD3C4', 'first time here, the vibes are great'),
      ('pixelwren', '#4FB3FF', 'oh lol thanks'),
      ('Tallgrass', '#7CD67C', 'clip that'),
      ('Saltmarsh', '#FFD166', 'hi chat'),
      ('quietfox', '#F2A93B', 'the music in this level is so good'),
    ];
    for (final (i, (name, color, text)) in lines.indexed) {
      final login = name.toLowerCase();
      read.handleLine(
        '@id=m$i;display-name=$name;color=$color :$login!$login'
        '@$login.tmi.twitch.tv PRIVMSG #camila :$text',
      );
    }
    await tester.pump(const Duration(milliseconds: 600));
    return read;
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    final item = find.text('Edit layout', skipOffstage: false).last;
    // The glass menu opens downward from the bottom row, off screen.
    final tall = tester.getCenter(item).dy > 850;
    if (tall) {
      tester.view.physicalSize = const Size(1080, 3600);
      await tester.pumpAndSettle();
    }
    await tester.tap(item);
    if (tall) {
      await tester.pump(const Duration(milliseconds: 200));
      tester.view.physicalSize = const Size(1080, 2340);
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('render fullscreen', (tester) async {
    await boot(tester, {'layout_density': 'compact', 'liquid_glass': true});
    Future<void> pick(String label) async {
      await tester.tap(find.byIcon(Icons.expand_more).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await pick('Toggle fullscreen');
    await _shot(tester, 'fullscreen');
    await pick('Toggle input');
    await _shot(tester, 'fullscreen_no_input');
    await tester.pump(const Duration(seconds: 30));
  });

  for (final preset in ChromeTheme.values) {
    testWidgets('render preset ${preset.name}', (tester) async {
      await boot(tester, {
        'layout_density': 'compact',
        'liquid_glass': true,
        'chrome_theme': preset.name,
      });
      await _shot(tester, 'preset_${preset.name}');
      await tester.pump(const Duration(seconds: 30));
    });
  }

  testWidgets('render side column', (tester) async {
    await boot(tester, {'layout_density': 'compact'});
    await openEditor(tester);
    // Compact keeps send in the field, so the column needs it off.
    await tester.tap(find.text('Hide row while typing'));
    await tester.pump(const Duration(milliseconds: 300));
    final send = find.byIcon(Icons.send).first;
    final gesture = await tester.startGesture(tester.getCenter(send));
    await tester.pump(const Duration(milliseconds: 250));
    final island = tester.getRect(find.byKey(const Key('bottom_chrome_bar')));
    await gesture.moveTo(Offset(island.right - 20, island.top));
    await tester.pump(const Duration(milliseconds: 100));
    final right = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await gesture.moveTo(Offset(right - 34, island.center.dy - 30));
    await _shot(tester, 'side_drag', settle: const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, 'side_placed');
    await tester.pump(const Duration(seconds: 30));
  });

  final scenarios = <String, Map<String, Object>>{
    'compact': {'layout_density': 'compact'},
    'compact_glass': {'layout_density': 'compact', 'liquid_glass': true},
    'comfortable': {'layout_density': 'comfortable'},
  };
  for (final MapEntry(key: name, value: prefs) in scenarios.entries) {
    testWidgets('render $name', (tester) async {
      await boot(tester, prefs);
      await _shot(tester, '${name}_home');
      await openEditor(tester);
      await _shot(tester, '${name}_edit');
      await tester.tap(find.byIcon(Icons.forum_outlined).first);
      await tester.pumpAndSettle();
      await _shot(tester, '${name}_edit_menu');
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined).first);
      await tester.pumpAndSettle();
      await _shot(tester, '${name}_edit_menu_blocked');
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.forum_outlined).first),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(380, 44));
      await _shot(tester, '${name}_edit_drag_strip');
      await gesture.moveTo(const Offset(200, 640));
      await _shot(tester, '${name}_edit_drag_tray');
      await gesture.up();
      await tester.pumpAndSettle();
      // Emote leaves the field: room on both sides of the text field.
      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Row, left'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));
      await _shot(tester, '${name}_edit_field_room');
      // A row action dragged onto the start "+" fills the field row.
      final plus = find.descendant(
        of: find.byType(TextField),
        matching: find.byIcon(Icons.add),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.forum_outlined).first),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await drag.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 100));
      await drag.moveTo(tester.getCenter(plus.first));
      await _shot(tester, '${name}_edit_field_drag');
      await drag.up();
      await tester.pumpAndSettle();
      await _shot(tester, '${name}_edit_field_full');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await _shot(tester, '${name}_saved_home');
      await tester.pump(const Duration(seconds: 30));
    });
  }

  // The loading ring around the island, at several points of its cycle.
  final ringScenarios = <String, Map<String, Object>>{
    'ring_float': {
      'chrome_theme': 'custom:0',
      'chrome_themes_custom': [
        ChromeTheme.ermchat.spec
            .copyWith(busyBar: true, sendAside: SendPlace.column)
            .encode(),
      ],
    },
    'ring_float_glass': {
      'chrome_theme': 'custom:0',
      'liquid_glass': true,
      'chrome_themes_custom': [
        ChromeTheme.ermchat.spec
            .copyWith(busyBar: true, sendAside: SendPlace.column)
            .encode(),
      ],
    },
    'ring_flush': {'chrome_theme': 'dankchat4'},
  };
  for (final MapEntry(key: name, value: prefs) in ringScenarios.entries) {
    testWidgets('render $name', (tester) async {
      final read = await boot(tester, prefs);
      HomeScreen.disableJoinSpinner = false;
      // Dropping the socket makes the chat read as loading.
      read.triggerDisconnect();
      await tester.pump(const Duration(milliseconds: 250));
      var at = 0;
      for (final ms in [0, 300, 700, 1100, 1500]) {
        await tester.pump(Duration(milliseconds: ms - at));
        at = ms;
        await _shot(tester, '${name}_$ms', settle: Duration.zero);
      }
      await tester.pump(const Duration(seconds: 30));
    });
  }
}
