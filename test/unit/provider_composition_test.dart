import 'package:ermchat/providers/app_providers.dart';
import 'package:ermchat/providers/chat_pipeline.dart';
import 'package:ermchat/providers/emote_providers.dart';
import 'package:ermchat/providers/feature_providers.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/emote_store.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/irc/proxy_config.dart';
import 'package:ermchat/util/prefs.dart';

/// Counts how many times the pipeline's construction reached the API provider.
/// Reset per test to prove laziness.
int _twitchApiBuilds = 0;

class _TrackedTwitchApi extends TwitchApi {
  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _TrackedUserStore extends UserStore {
  bool disposed = false;
}

class _ChangeTrackingStore extends EmoteStore {
  int stateCleared = 0;

  @override
  void notifyCatalogChanged() {
    stateCleared++;
    super.notifyCatalogChanged();
  }
}

/// Boots the real provider graph. Only [twitchApiProvider] (to observe
/// construction and teardown) and, when supplied, [userStoreProvider] are
/// overridden; everything else is the production instance.
ProviderContainer _boot({_TrackedUserStore? userStore}) {
  return ProviderContainer(
    overrides: [
      twitchApiProvider.overrideWith((ref) {
        _twitchApiBuilds++;
        final api = _TrackedTwitchApi();
        ref.onDispose(api.close);
        return api;
      }),
      if (userStore != null)
        userStoreProvider.overrideWith((ref) {
          ref.onDispose(() => userStore.disposed = true);
          return userStore;
        }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _twitchApiBuilds = 0;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('chatPipelineProvider builds a manager from shared instances', () {
    final container = _boot();
    addTearDown(container.dispose);

    container.read(chatProvider);
    container.read(sessionProvider);
    expect(_twitchApiBuilds, 0, reason: 'pipeline graph is lazy');

    final manager = container.read(chatPipelineProvider);
    expect(manager, isA<ChatConnectionManager>());
    expect(_twitchApiBuilds, 1);
    expect(identical(container.read(chatPipelineProvider), manager), isTrue);

    expect(
      identical(manager.config.chat, container.read(chatProvider)),
      isTrue,
    );
    expect(
      identical(manager.config.session, container.read(sessionProvider)),
      isTrue,
    );

    final services = manager.config.services;
    expect(
      identical(services.twitchApi, container.read(twitchApiProvider)),
      isTrue,
    );
    expect(
      identical(services.eventSub, container.read(eventSubServiceProvider)),
      isTrue,
    );
    expect(identical(services.irc, container.read(ircServiceProvider)), isTrue);
    expect(
      identical(services.ircRead, container.read(ircReadServiceProvider)),
      isTrue,
    );
    expect(
      identical(services.emoteManager, container.read(emoteManagerProvider)),
      isTrue,
    );
    expect(
      identical(services.badgeService, container.read(badgeServiceProvider)),
      isTrue,
    );
    expect(
      identical(services.userStore, container.read(userStoreProvider)),
      isTrue,
    );
    expect(
      identical(services.twitchAuth, container.read(twitchAuthProvider)),
      isTrue,
    );
  });

  test('personal-set notifications bump the shared version', () {
    final store = _ChangeTrackingStore();
    final container = ProviderContainer(
      overrides: [emoteStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    final personalSets = container.read(sevenTvPersonalSetsProvider);
    personalSets.viewerTwitchId = 'diagnostic-viewer';

    expect(store.stateCleared, 1);
    expect(store.version, 1);
  });

  test('container disposal runs owners and blocks further reads', () {
    final store = _TrackedUserStore();
    final container = _boot(userStore: store);
    addTearDown(container.dispose);

    final manager = container.read(chatPipelineProvider);
    expect(identical(manager.config.services.userStore, store), isTrue);
    final api = container.read(twitchApiProvider) as _TrackedTwitchApi;
    expect(store.disposed, isFalse);
    expect(api.closed, isFalse);

    // Any throwing onDispose in the graph fails this call.
    container.dispose();
    expect(store.disposed, isTrue);
    expect(api.closed, isTrue);
    expect(() => container.read(chatProvider), throwsStateError);
  });

  test(
    'proxy config round trips and only overrides the socket with a url',
    () async {
      Future<ProxyConfig> roundTrip(ProxyConfig? saved) async {
        SharedPreferences.setMockInitialValues({});
        if (saved != null) await saved.toPrefs(await Prefs.load());
        return ProxyConfig.fromPrefs(await Prefs.load());
      }

      expect((await roundTrip(null)).enabled, isFalse);
      expect((await roundTrip(null)).readWsUrl, isNull);
      const url = 'ws://192.168.1.10:8080/ws';
      expect(
        (await roundTrip(const ProxyConfig(enabled: true, url: url))).readWsUrl,
        url,
      );
      expect(
        (await roundTrip(const ProxyConfig(enabled: true))).readWsUrl,
        isNull,
      );
    },
  );

  // The app root rebuilds on every settings write with a fresh config. The
  // read socket must survive it: the pipeline holds this exact instance.
  test('settings writes never replace the live read socket', () {
    final container = ProviderContainer(
      overrides: [proxyConfigProvider.overrideWithValue(const ProxyConfig())],
    );
    addTearDown(container.dispose);
    final read = container.read(ircReadServiceProvider);

    container.updateOverrides([
      // A new but equal instance, as ProxyConfig.fromPrefs builds.
      // ignore: prefer_const_constructors
      proxyConfigProvider.overrideWithValue(ProxyConfig()),
    ]);
    expect(container.read(ircReadServiceProvider), same(read));

    container.updateOverrides([
      proxyConfigProvider.overrideWithValue(
        const ProxyConfig(enabled: true, url: 'ws://proxy/ws'),
      ),
    ]);
    expect(container.read(ircReadServiceProvider), same(read));
  });
}
