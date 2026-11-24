import 'package:ermchat/util/prefs.dart';
import 'package:http/http.dart' as http;

import 'widget_test_harness.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // Tests keep the app in a disconnected (never "online") state, so the join
    // button's loading spinner would spin forever and block the "+". Disable it
    // for the suite; the behavior itself is exercised in the real app.
    HomeScreen.disableJoinSpinner = true;
  });

  group('Settings screen', () {
    testWidgets('Channel settings reorder, join, and enforce the cap', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      List<String>? reordered;

      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier(['a', 'b', 'c']),
            onReorderChannels: (channels) => reordered = channels,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a', skipOffstage: false)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      // Drag down by more than one row height to trigger reorder.
      final rowHeight = tester
          .getSize(find.text('a', skipOffstage: false))
          .height;
      await gesture.moveBy(Offset(0, rowHeight * 2));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reordered, isNotNull);
      expect(reordered, isNot(equals(['a', 'b', 'c'])));

      SharedPreferences.setMockInitialValues({});
      final added = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier([]),
            onAddChannel: added.add,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Add channels', skipOffstage: false));
      await tester.pumpAndSettle();

      expect(find.text('Add channels', skipOffstage: false), findsWidgets);
      expect(find.text('Cancel', skipOffstage: false), findsOneWidget);
      expect(find.text('Add', skipOffstage: false), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).last,
        'newchannel, second channel',
      );
      await tester.tap(find.text('Add', skipOffstage: false).last);
      await tester.pumpAndSettle();

      expect(added, ['newchannel', 'second', 'channel']);

      SharedPreferences.setMockInitialValues({});
      String? addedChannel;
      final channels = List.generate(kMaxChannels, (i) => 'ch$i');
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: ChannelSettingsScreen(
            channelNotifier: ValueNotifier(channels),
            onAddChannel: (ch) => addedChannel = ch,
          ),
        ),
      );
      await tester.pump();

      // The Join button sits below the capped list, so it starts offstage.
      // Jump straight to the bottom in one drag instead of stepping
      // through every row.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -5000));
      await tester.pumpAndSettle();

      // At the cap the Add channels button is disabled, so tapping it opens no
      // dialog and never fires onAddChannel.
      final joinFinder = find.text('Add channels', skipOffstage: false);
      expect(joinFinder, findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(
                OutlinedButton,
                'Add channels',
                skipOffstage: false,
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(joinFinder, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(addedChannel, isNull);
      expect(find.text('Cancel', skipOffstage: false), findsNothing);
    });

    testWidgets('Emote cache size applies only on apply and evicts on zero', (
      WidgetTester tester,
    ) async {
      {
        SharedPreferences.setMockInitialValues({});
        await Prefs.load();
        int? applied;

        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: EmotesSettingsScreen(
              onEmoteCacheMaxChanged: (value) => applied = value,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        // The Animation section pushes the cache rows below the fold.
        await tester.scrollUntilVisible(
          find.byKey(const Key('emote_cache_slider')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        final slider = tester.widget<Slider>(
          find.byKey(const Key('emote_cache_slider')),
        );
        slider.onChanged!(200.0);
        await tester.pump();

        expect(applied, isNull);
        var prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('emote_cache_mb'), isNull);
        // Rough estimate extrapolates from the fallback average when empty.
        expect(
          find.text('200 MB (~5120 emotes)', skipOffstage: false),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('emote_cache_apply')));
        await tester.pump();
        await tester.pump();

        expect(applied, 200);
        prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('emote_cache_mb'), 200);
      }
      {
        SharedPreferences.setMockInitialValues({
          'emote_fetch_auto': EmoteFetchAutoMode.off.index,
        });
        final repo = FakeCacheRepo();
        final t = DateTime(2026, 1, 1, 12);
        repo.seed([
          CacheObject(
            'https://example.com/a.png',
            id: 1,
            relativePath: 'a.png',
            validTill: DateTime(2030),
            touched: t,
          ),
          CacheObject(
            'https://example.com/b.png',
            id: 2,
            relativePath: 'b.png',
            validTill: DateTime(2030),
            touched: t.add(const Duration(hours: 1)),
          ),
          CacheObject(
            'https://example.com/c.png',
            id: 3,
            relativePath: 'c.png',
            validTill: DateTime(2030),
            touched: t.add(const Duration(hours: 2)),
          ),
        ]);
        final manager = EmoteCacheManager.forTesting(
          Config('test', repo: repo, fileSystem: MemoryCacheSystem()),
        );

        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: EmotesSettingsScreen(
              images: EmoteImages(cacheManager: manager),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        // The Animation section pushes the cache rows below the fold.
        await tester.scrollUntilVisible(
          find.byKey(const Key('emote_cache_slider')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        final slider = tester.widget<Slider>(
          find.byKey(const Key('emote_cache_slider')),
        );
        slider.onChanged!(0);
        await tester.pump();

        await tester.tap(find.byKey(const Key('emote_cache_apply')));
        await tester.pump();
        await tester.pump();

        expect(repo.keys, isEmpty);

        // Let the cache store's one-shot cleanup timer fire so the test ends
        // without pending timers.
        await tester.pump(const Duration(seconds: 10));
      }
    });
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget wrapAccountScreen(TwitchAuth auth) {
    return MaterialApp(
      key: UniqueKey(),
      home: AccountScreen(twitchAuth: auth),
    );
  }

  TwitchAuth twoAccounts() {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'token_a');
    auth.setUser('alice', '111', profileImageUrl: 'https://example.com/a.png');
    auth.setCredentials(accessToken: 'token_b');
    auth.setUser('bob', '222');
    return auth;
  }

  Future<void> expectReLogin(
    WidgetTester tester,
    void Function(TwitchAuth auth) mark,
  ) async {
    final auth = TwitchAuth();
    auth.setCredentials(accessToken: 'old-token');
    auth.setUser('alice', '111');
    mark(auth);
    var calls = 0;
    final api = TwitchApi(
      client: MockClient((request) async {
        return http.Response(
          '{"data":[{"id":"111","login":"alice","display_name":"Alice"}]}',
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: AccountScreen(
          twitchAuth: auth,
          twitchApi: api,
          oAuthStarter: () async {
            calls++;
            return 'new-token';
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Log in again', skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('Log in again', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(auth.accessToken, 'new-token');
    expect(auth.isActiveExpired, isFalse);
    expect(auth.scopeStale, isFalse);
  }

  testWidgets('saved and anonymous account switches preserve isolation', (
    WidgetTester tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();
    expect(auth.login, 'bob');

    await tester.tap(find.text('alice', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(auth.login, 'alice');
    expect(auth.accessToken, 'token_a');

    await auth.switchTo('bob');
    await tester.pumpAndSettle();
    expect(auth.login, 'bob');
    expect(find.text('Anonymous', skipOffstage: false), findsOneWidget);
    expect(find.text('Active', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Anonymous', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(auth.isAnonymous, isTrue);
    expect(auth.accessToken, isNull);
    // The registry is kept, so switching back restores the token.
    expect(auth.accounts.length, 2);
    expect(find.text('Active', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Log in', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('alice', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(auth.login, 'alice');
    expect(auth.accessToken, 'token_a');
  });

  testWidgets('stale scopes and expired tokens offer a one-tap re-login', (
    tester,
  ) async {
    for (final mark in [
      (TwitchAuth auth) => auth.markScopeStale(),
      (TwitchAuth auth) => auth.markActiveExpired(),
    ]) {
      await expectReLogin(tester, mark);
    }
  });

  testWidgets('Disconnect asks for confirmation and falls back to login', (
    WidgetTester tester,
  ) async {
    {
      final auth = twoAccounts();
      await tester.pumpWidget(wrapAccountScreen(auth));
      await tester.pump();

      await tester.tap(find.text('Disconnect', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(find.text('Remove account?', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Are you sure you want to remove @bob?', skipOffstage: false),
        findsOneWidget,
      );

      await tester.tap(find.text('Remove', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(auth.accounts.length, 1);
      expect(auth.accounts.single.login, 'alice');
      expect(find.text('bob'), findsNothing);
    }
    {
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      await tester.pumpWidget(wrapAccountScreen(auth));
      await tester.pump();

      await tester.tap(find.text('Disconnect', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove', skipOffstage: false));
      await tester.pumpAndSettle();

      expect(auth.accounts, isEmpty);
      expect(find.text('Log in', skipOffstage: false), findsOneWidget);
    }
  });
}
