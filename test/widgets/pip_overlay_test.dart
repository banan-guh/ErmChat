import 'package:ermchat/widgets/stream_player_view.dart';
import '../helpers/fake_pip_service.dart';
import '../helpers/fake_webview_platform.dart';
import 'widget_test_harness.dart';

// PiP renders the whole activity, so the app root draws the stream above every
// route while PiP is active. The home screen must stop drawing its own player
// then: both would share the same GlobalKey and crash. This guards the rare
// "enter PiP from settings" flow.
void main() {
  setUp(() {
    installFakeWebViewPlatform();
    HomeScreen.disableJoinSpinner = true;
  });

  testWidgets('PiP draws one player above a pushed route', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final fakePip = FakePipService();
    await tester.pumpWidget(
      TwitchChatApp(
        key: UniqueKey(),
        eventSubService: FakeEventSubService(),
        recentMessagesService: FakeRecentMessagesService(),
        ircService: FakeIrcService(),
        ircReadService: FakeIrcReadService(),
        pipService: fakePip,
      ),
    );
    await tester.pump();

    // Start a stream so a player exists to hand off.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    container.read(streamPlayerProvider).toggleStream('xqc');
    await tester.pump();

    // Push a page over the home screen, the way settings opens.
    Navigator.of(tester.element(find.byType(HomeScreen))).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('settings-page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('settings-page'), findsOneWidget);

    // Enter PiP from the pushed route.
    fakePip.triggerPipChanged(true);
    await tester.pumpAndSettle();

    final players = find.byType(StreamPlayerView);
    expect(players, findsOneWidget);
    expect(
      find.ancestor(of: players, matching: find.byType(Navigator)),
      findsNothing,
      reason: 'the player must draw above the Navigator during PiP',
    );
    expect(find.text('settings-page'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Leaving PiP returns to the route that was underneath.
    fakePip.triggerPipChanged(false);
    await tester.pumpAndSettle();
    expect(find.text('settings-page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
