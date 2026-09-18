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
    testWidgets(
      'Account screen runs the full idle to connected to lookup to disconnect lifecycle',
      (WidgetTester tester) async {
        {
          SharedPreferences.setMockInitialValues({});
          final auth = TwitchAuth();

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: AccountScreen(twitchAuth: auth),
            ),
          );
          await tester.pump();

          expect(find.text('Account', skipOffstage: false), findsOneWidget);
          expect(find.text('Login', skipOffstage: false), findsOneWidget);
          expect(find.text('Connected'), findsNothing);
        }
        {
          SharedPreferences.setMockInitialValues({});
          final auth = TwitchAuth()..accessToken = 'test-token';

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: AccountScreen(twitchAuth: auth),
            ),
          );
          await tester.pump();

          expect(find.text('Connected', skipOffstage: false), findsOneWidget);
          expect(find.text('Disconnect', skipOffstage: false), findsOneWidget);
          expect(find.text('Login'), findsNothing);
        }
        {
          SharedPreferences.setMockInitialValues({});
          final auth = TwitchAuth()..accessToken = 'test-token';
          final api = TwitchApi(
            client: MockClient((request) async {
              return http.Response(
                '{"data":[{"id":"1","login":"testuser","display_name":"TestUser"}]}',
                200,
              );
            }),
          );

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: AccountScreen(twitchAuth: auth, twitchApi: api),
            ),
          );
          await tester.pump();
          await tester.pump();

          expect(
            find.text('Connected as testuser', skipOffstage: false),
            findsOneWidget,
          );
          expect(find.text('Connected'), findsNothing);
        }
        {
          SharedPreferences.setMockInitialValues({});
          final auth = TwitchAuth()..accessToken = 'test-token';

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: AccountScreen(twitchAuth: auth),
            ),
          );
          await tester.pump();

          expect(find.text('Connected', skipOffstage: false), findsOneWidget);

          await tester.tap(find.text('Disconnect', skipOffstage: false));
          await tester.pump();
          await tester.pump();

          expect(find.text('Connected'), findsNothing);
          expect(find.text('Login', skipOffstage: false), findsOneWidget);
        }
      },
    );

    testWidgets('Customization true dark toggle is disabled in light mode', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      bool? changed;

      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onTrueDarkChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      await tester.scrollUntilVisible(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
        120,
        scrollable: find.byType(Scrollable).first,
      );

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
      );
      expect(tile.onChanged, isNull);

      await tester.tap(find.widgetWithText(SwitchListTile, 'True dark mode'));
      await tester.pumpAndSettle();

      expect(changed, isNull);
    });

    testWidgets('Customization true dark toggle persists and calls '
        'onTrueDarkChanged', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      bool? changed;

      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: ThemeMode.dark,
          home: CustomizationScreen(
            onThemeChanged: (_) {},
            onTrueDarkChanged: (value) => changed = value,
          ),
        ),
      );
      await tester.pump();

      await tester.scrollUntilVisible(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
        120,
        scrollable: find.byType(Scrollable).first,
      );

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'True dark mode'),
      );
      expect(tile.value, isFalse);

      await tester.tap(find.widgetWithText(SwitchListTile, 'True dark mode'));
      await tester.pumpAndSettle();

      expect(changed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('true_dark'), isTrue);
    });

    testWidgets('Channel settings drag handle reorders channels', (
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
    });

    testWidgets(
      'Channel settings join dialog validates input and blocks at the cap',
      (WidgetTester tester) async {
        {
          SharedPreferences.setMockInitialValues({});
          String? addedChannel;

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: ChannelSettingsScreen(
                channelNotifier: ValueNotifier([]),
                onAddChannel: (ch) => addedChannel = ch,
              ),
            ),
          );
          await tester.pump();

          await tester.tap(find.text('Join channel', skipOffstage: false));
          await tester.pumpAndSettle();

          expect(find.text('Join channel', skipOffstage: false), findsWidgets);
          expect(find.text('Cancel', skipOffstage: false), findsOneWidget);
          expect(find.text('Join', skipOffstage: false), findsOneWidget);

          await tester.enterText(find.byType(TextField).last, 'newchannel');
          await tester.tap(find.text('Join', skipOffstage: false).last);
          await tester.pumpAndSettle();

          expect(addedChannel, 'newchannel');
        }
        {
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
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -5000),
          );
          await tester.pumpAndSettle();

          // At the cap the Join channel button is disabled, so tapping it opens no
          // dialog and never fires onAddChannel.
          final joinFinder = find.text('Join channel', skipOffstage: false);
          expect(joinFinder, findsOneWidget);
          expect(
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(
                    OutlinedButton,
                    'Join channel',
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
        }
      },
    );

    testWidgets('Chat settings timestamp toggle and format picker persist', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        MaterialApp(key: UniqueKey(), home: ChatSettingsScreen()),
      );
      await tester.pump();

      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(
          SwitchListTile,
          'Show timestamps',
          skipOffstage: false,
        ),
      );
      expect(toggle.value, isTrue);
      // Interact with the toggle before scrolling down: the lazy ListView
      // disposes items that scroll out of the cache extent, so bring it into
      // view first (otherwise the tap misses and nothing is persisted).
      await tester.ensureVisible(
        find.widgetWithText(
          SwitchListTile,
          'Show timestamps',
          skipOffstage: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          SwitchListTile,
          'Show timestamps',
          skipOffstage: false,
        ),
      );
      await tester.pumpAndSettle();
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('show_timestamps'), isFalse);
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, 'Timestamp format', skipOffstage: false),
        120,
      );
      await tester.pumpAndSettle();
      expect(find.text('HH:mm', skipOffstage: false), findsOneWidget);

      final formatTile = find.widgetWithText(ListTile, 'Timestamp format');
      await tester.ensureVisible(formatTile);
      await tester.pumpAndSettle();
      await tester.tap(formatTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('h:mm a', skipOffstage: false));
      await tester.pumpAndSettle();

      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('timestamp_format'), 'h:mm a');
      expect(find.text('h:mm a', skipOffstage: false), findsOneWidget);
    });

    testWidgets('max messages slider is log-scaled and snaps to steps', (
      WidgetTester tester,
    ) async {
      // Legacy value between steps snaps to the nearest log-scale step.
      SharedPreferences.setMockInitialValues({'max_messages_per_channel': 275});

      await tester.pumpWidget(
        MaterialApp(key: UniqueKey(), home: ChatSettingsScreen()),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Max messages per channel: 300', skipOffstage: false),
        findsOneWidget,
      );

      final slider = tester.widget<Slider>(find.byType(Slider).first);
      expect(slider.min, 0);
      expect(slider.max, 9);
      expect(slider.divisions, 9);

      // Tap the far right of the track: snaps to the max step (5000).
      final rect = tester.getRect(find.byType(Slider).first);
      await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Max messages per channel: 5000', skipOffstage: false),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('max_messages_per_channel'), 5000);
    });

    testWidgets(
      'Emote fetch tier follows manual changes and auto mode and connectivity',
      (WidgetTester tester) async {
        {
          SharedPreferences.setMockInitialValues({
            'emote_fetch_auto': EmoteFetchAutoMode.off.index,
          });
          int? changed;

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: EmotesSettingsScreen(
                onEmoteTierChanged: (value) => changed = value,
              ),
            ),
          );
          await tester.pump();
          await tester.pump();

          final slider = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          // The tier change (persist + callback + refetch cascade) fires on
          // release, not per drag tick.
          slider.onChangeEnd!(EmoteFetchTier.low.index.toDouble());
          await tester.pump();
          await tester.pump();

          expect(changed, EmoteFetchTier.low.index);
          expect(find.text('Low', skipOffstage: false), findsOneWidget);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getInt('emote_fetch_tier'), EmoteFetchTier.low.index);
        }
        {
          SharedPreferences.setMockInitialValues({});
          EmoteFetchAutoMode? changed;

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: EmotesSettingsScreen(
                onEmoteAutoModeChanged: (mode) => changed = mode,
              ),
            ),
          );
          await tester.pump();
          await tester.pump();

          expect(find.byKey(const Key('emote_auto_mode')), findsOneWidget);
          // Auto mode defaults to Balanced, so the manual tier slider is locked.
          expect(find.text('Balanced', skipOffstage: false), findsOneWidget);
          var slider = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          expect(slider.onChanged, isNull);

          await tester.tap(find.text('Aggressive', skipOffstage: false));
          await tester.pump();
          await tester.pump();

          expect(changed, EmoteFetchAutoMode.aggressive);
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getInt('emote_fetch_auto'),
            EmoteFetchAutoMode.aggressive.index,
          );
          slider = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          expect(slider.onChanged, isNull);

          await tester.tap(find.text('Off', skipOffstage: false));
          await tester.pump();
          await tester.pump();

          expect(changed, EmoteFetchAutoMode.off);
          final unlocked = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          expect(unlocked.onChanged, isNotNull);
        }
        {
          SharedPreferences.setMockInitialValues({
            'emote_fetch_auto': EmoteFetchAutoMode.balanced.index,
          });
          final mobile = ValueNotifier<bool>(true);

          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: EmotesSettingsScreen(mobileNotifier: mobile),
            ),
          );
          await tester.pump();
          await tester.pump();

          // Balanced + cellular => Low is being picked and shown on the slider.
          expect(find.text('Low', skipOffstage: false), findsOneWidget);
          var slider = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          expect(slider.value, EmoteFetchTier.low.index.toDouble());
          expect(slider.onChanged, isNull);

          // Hand off to Wi-Fi while the screen is open: the tier animates up to
          // High; wait for the animation to settle before asserting the value.
          mobile.value = false;
          await tester.pumpAndSettle();
          expect(find.text('High', skipOffstage: false), findsOneWidget);
          expect(find.text('Low'), findsNothing);
          slider = tester.widget<Slider>(
            find.byKey(const Key('emote_tier_slider')),
          );
          expect(slider.value, EmoteFetchTier.high.index.toDouble());
        }
      },
    );

    testWidgets('provider toggles flip the manager and persist', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final manager = EmoteManager(
        fetchStagger: Duration.zero,
        tier: EmoteFetchTier.nothing,
      );

      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: EmotesSettingsScreen(emoteManager: manager),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The Animation section pushes the provider rows below the fold of
      // the lazy list; bring them on stage first.
      await tester.scrollUntilVisible(
        find.byKey(const Key('providers_tile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // Twitch is always on and not offered as an option.
      expect(find.byKey(const Key('provider_toggle_twitch')), findsNothing);
      expect(find.text('Providers', skipOffstage: false), findsOneWidget);

      // The picker lives in a bottom sheet at the bottom of the page.
      expect(find.byKey(const Key('provider_toggle_bttv')), findsNothing);
      await tester.tap(find.byKey(const Key('providers_tile')));
      await tester.pumpAndSettle();
      expect(find.text('BetterTTV', skipOffstage: false), findsOneWidget);
      expect(find.text('FrankerFaceZ', skipOffstage: false), findsOneWidget);
      expect(find.text('7TV', skipOffstage: false), findsOneWidget);

      await tester.tap(find.byKey(const Key('provider_toggle_bttv')));
      await tester.pump();

      expect(manager.isProviderEnabled(EmoteType.bttv), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('emote_providers_disabled'), ['bttv']);
    });

    testWidgets('Emote cache size applies only on apply and evicts on zero', (
      WidgetTester tester,
    ) async {
      {
        SharedPreferences.setMockInitialValues({});
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
        slider.onChanged!(100.0);
        await tester.pump();

        expect(applied, isNull);
        var prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('emote_cache_mb'), isNull);
        // Rough estimate extrapolates from the fallback average when empty.
        expect(
          find.text('100 MB (~2560 emotes)', skipOffstage: false),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('emote_cache_apply')));
        await tester.pump();
        await tester.pump();

        expect(applied, 100);
        prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('emote_cache_mb'), 100);
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

  group('Tools settings', () {
    testWidgets(
      'Tools screen links to helpers and hides analytics without a service',
      (WidgetTester tester) async {
        {
          SharedPreferences.setMockInitialValues({});
          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: ToolsSettingsScreen(
                analyticsService: AnalyticsService(),
                channels: ['channel1'],
                images: EmoteImages(),
              ),
            ),
          );
          await tester.pump();

          expect(find.text('Tools', skipOffstage: false), findsOneWidget);
          expect(
            find.text('Image uploader', skipOffstage: false),
            findsOneWidget,
          );
          expect(
            find.text('Recent uploads', skipOffstage: false),
            findsOneWidget,
          );
          expect(find.text('Analytics', skipOffstage: false), findsOneWidget);

          await tester.tap(find.text('Image uploader', skipOffstage: false));
          await tester.pumpAndSettle();
          expect(
            find.text('Image uploader', skipOffstage: false),
            findsWidgets,
          );
          expect(find.text('Save', skipOffstage: false), findsOneWidget);
        }
        {
          SharedPreferences.setMockInitialValues({});
          await tester.pumpWidget(
            MaterialApp(key: UniqueKey(), home: ToolsSettingsScreen()),
          );
          await tester.pump();

          expect(
            find.text('Image uploader', skipOffstage: false),
            findsOneWidget,
          );
          expect(
            find.text('Recent uploads', skipOffstage: false),
            findsOneWidget,
          );
          expect(find.text('Analytics'), findsNothing);
        }
        {
          SharedPreferences.setMockInitialValues({});
          await tester.pumpWidget(
            MaterialApp(key: UniqueKey(), home: ToolsSettingsScreen()),
          );
          await tester.pump();

          expect(
            find.text('Recent messages', skipOffstage: false),
            findsOneWidget,
          );

          await tester.tap(find.text('Recent messages', skipOffstage: false));
          await tester.pumpAndSettle();

          // The recent-messages settings screen exposes the four provider modes.
          expect(find.text('Auto', skipOffstage: false), findsOneWidget);
          expect(
            find.text('Robotty only', skipOffstage: false),
            findsOneWidget,
          );
          expect(find.text('Zneix only', skipOffstage: false), findsOneWidget);
          expect(find.text('Custom URL', skipOffstage: false), findsOneWidget);
        }
      },
    );
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

  testWidgets(
    'Saved accounts list marks the active account and switch on tap',
    (WidgetTester tester) async {
      {
        final auth = twoAccounts();
        await tester.pumpWidget(wrapAccountScreen(auth));
        await tester.pump();

        expect(find.text('Accounts', skipOffstage: false), findsOneWidget);
        expect(find.text('alice', skipOffstage: false), findsOneWidget);
        expect(find.text('bob', skipOffstage: false), findsOneWidget);
        expect(find.text('Active', skipOffstage: false), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);
      }
      {
        final auth = twoAccounts();
        await tester.pumpWidget(wrapAccountScreen(auth));
        await tester.pump();
        expect(auth.login, 'bob');

        await tester.tap(find.text('alice', skipOffstage: false));
        await tester.pumpAndSettle();
        expect(auth.login, 'alice');
        expect(auth.accessToken, 'token_a');
      }
    },
  );

  testWidgets('Anonymous row is present and selected with no accounts', (
    WidgetTester tester,
  ) async {
    final auth = TwitchAuth();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();

    expect(find.text('Accounts', skipOffstage: false), findsOneWidget);
    expect(find.text('Anonymous', skipOffstage: false), findsOneWidget);
    expect(find.text('Active', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('Login', skipOffstage: false), findsOneWidget);
  });

  testWidgets('Anonymous row switches to and from saved accounts', (
    WidgetTester tester,
  ) async {
    final auth = twoAccounts();
    await tester.pumpWidget(wrapAccountScreen(auth));
    await tester.pump();
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
    expect(find.text('Login', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('alice', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(auth.login, 'alice');
    expect(auth.accessToken, 'token_a');
  });

  testWidgets(
    'Saved account removal asks for confirmation and falls back to login',
    (WidgetTester tester) async {
      {
        final auth = twoAccounts();
        await tester.pumpWidget(wrapAccountScreen(auth));
        await tester.pump();

        await tester.longPress(find.text('alice', skipOffstage: false));
        await tester.pumpAndSettle();
        expect(
          find.text('Remove account?', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(
            'Are you sure you want to remove @alice?',
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Remove', skipOffstage: false));
        await tester.pumpAndSettle();
        expect(auth.accounts.length, 1);
        expect(auth.accounts.single.login, 'bob');
        expect(find.text('alice'), findsNothing);
      }
      {
        final auth = twoAccounts();
        await tester.pumpWidget(wrapAccountScreen(auth));
        await tester.pump();

        await tester.longPress(find.text('alice', skipOffstage: false));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel', skipOffstage: false));
        await tester.pumpAndSettle();

        expect(auth.accounts.length, 2);
        expect(find.text('alice', skipOffstage: false), findsOneWidget);
      }
      {
        final auth = TwitchAuth();
        auth.setCredentials(accessToken: 'token_a');
        auth.setUser('alice', '111');
        await tester.pumpWidget(wrapAccountScreen(auth));
        await tester.pump();

        await tester.longPress(find.text('alice', skipOffstage: false));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove', skipOffstage: false));
        await tester.pumpAndSettle();

        expect(auth.accounts, isEmpty);
        expect(find.text('Login', skipOffstage: false), findsOneWidget);
      }
    },
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  AnalyticsService seededService() {
    final service = AnalyticsService();
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'alice', text: 'hello world', channel: 'chan1'),
    );
    service.recordMessage(
      'chan1',
      TwitchMessage(login: 'bob', text: 'hello', channel: 'chan1'),
    );
    service.recordMessage(
      'chan2',
      TwitchMessage(login: 'carol', text: 'yo', channel: 'chan2'),
    );
    return service;
  }

  Widget wrapAnalytics(AnalyticsService service, List<String> channels) {
    return MaterialApp(
      key: UniqueKey(),
      home: AnalyticsScreen(
        analyticsService: service,
        channels: channels,
        images: EmoteImages(),
      ),
    );
  }

  testWidgets('shows empty state when no channels', (tester) async {
    await tester.pumpWidget(wrapAnalytics(AnalyticsService(), []));
    await tester.pump();
    expect(
      find.text('Join a channel to start tracking stats', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('renders summary and top lists for the first channel', (
    tester,
  ) async {
    await tester.pumpWidget(wrapAnalytics(seededService(), ['chan1', 'chan2']));
    await tester.pump();

    expect(find.text('Total messages', skipOffstage: false), findsOneWidget);
    expect(find.text('Unique chatters', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Messages per minute', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Tracking for', skipOffstage: false), findsOneWidget);
    expect(find.text('Top chatters', skipOffstage: false), findsOneWidget);
    expect(find.text('Top emotes', skipOffstage: false), findsOneWidget);
    expect(find.text('Top words', skipOffstage: false), findsOneWidget);
    expect(find.text('alice', skipOffstage: false), findsOneWidget);
    expect(find.text('bob', skipOffstage: false), findsOneWidget);
  });
}
