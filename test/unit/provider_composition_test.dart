import 'package:ermchat/providers/app_providers.dart';
import 'package:ermchat/providers/chat_pipeline.dart';
import 'package:ermchat/providers/feature_providers.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    final manager = container.read(chatPipelineProvider);
    expect(manager, isA<ChatConnectionManager>());

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

  test('chatPipelineProvider is lazy until its first read', () {
    final container = _boot();
    addTearDown(container.dispose);

    // Reading non-dependencies touches nothing in the pipeline graph.
    container.read(chatProvider);
    container.read(sessionProvider);
    expect(_twitchApiBuilds, 0);

    final manager = container.read(chatPipelineProvider);
    expect(_twitchApiBuilds, 1);
    // A second read reuses the cached manager and re-builds nothing.
    expect(identical(container.read(chatPipelineProvider), manager), isTrue);
    expect(_twitchApiBuilds, 1);
  });

  test('chatUiSignalsProvider is stable across reads', () {
    final container = _boot();
    addTearDown(container.dispose);

    final first = container.read(chatUiSignalsProvider);
    final second = container.read(chatUiSignalsProvider);
    expect(identical(first, second), isTrue);
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
}
