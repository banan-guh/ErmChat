// Renders the layout editor to PNGs for eyeballing, not for asserting.
// Run: flutter test test/render/layout_editor_render.dart
// Output: build/render/*.png (1080x2340, real Roboto and Material icons).
import 'dart:io';
import 'dart:ui' as ui;

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

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
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
    for (var i = 0; i < 12; i++) {
      read.handleLine(
        '@id=m$i;display-name=chatter$i;color=#E05A9B :chatter$i!chatter$i'
        '@chatter$i.tmi.twitch.tv PRIVMSG #camila :message number $i here',
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
      final preview = find.byTooltip('Preview typing');
      if (preview.evaluate().isNotEmpty) {
        await tester.tap(preview);
        await tester.pump(const Duration(milliseconds: 500));
        await _shot(tester, '${name}_edit_typing');
        await tester.tap(preview);
        await tester.pump(const Duration(milliseconds: 500));
      }
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
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
