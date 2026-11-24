import 'package:ermchat/providers/app_providers.dart';
import 'package:ermchat/providers/chat_pipeline.dart';
import 'package:ermchat/providers/emote_providers.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ermchat/irc/proxy_config.dart';
import 'package:ermchat/util/prefs.dart';

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

/// Boots the real provider graph. Only [twitchApiProvider] (to observe
/// construction and teardown) and, when supplied, [userStoreProvider] are
/// overridden; everything else is the production instance.
ProviderContainer _boot({_TrackedUserStore? userStore}) {
  return ProviderContainer(
    overrides: [
      twitchApiProvider.overrideWith((ref) {
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
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('personal-set sender changes reach the manager without a cycle', () {
    final container = _boot();
    addTearDown(container.dispose);

    final manager = container.read(emoteManagerProvider);
    final seen = <Set<String>>[];
    manager.addPersonalSendersListener(seen.add);

    final sets = container.read(sevenTvPersonalSetsProvider);
    sets.onSendersChanged?.call({'42'});

    expect(seen, [
      {'42'},
    ]);
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
      for (final (url, used) in [
        ('ws://example.com/ws', false),
        ('wss://example.com/ws', true),
        ('ws://100.101.102.103:8080/ws', true),
        ('ws://172.32.0.1/ws', false),
        ('ws://mynas:8080/ws', true),
        ('ws://[::1]:8080/ws', true),
        ('ws://[fd12::1]/ws', true),
        ('ws://[2001:db8::1]/ws', false),
        ('ws://box.tail1234.ts.net/ws', true),
      ]) {
        expect(
          ProxyConfig(enabled: true, url: url).readWsUrl != null,
          used,
          reason: url,
        );
      }
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
