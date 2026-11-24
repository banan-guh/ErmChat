import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/services/emote_controller.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/emote_meta_store.dart';
import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/util/connectivity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingClient extends SevenTvEventClient {
  final ops = <String>[];

  @override
  void subscribeEmoteSet(String emoteSetId, {SevenTvEmoteSetOwner? owner}) {
    ops.add('sub:$emoteSetId');
    super.subscribeEmoteSet(emoteSetId, owner: owner);
  }

  @override
  void unsubscribeEmoteSet(String emoteSetId, {SevenTvEmoteSetOwner? owner}) {
    ops.add('unsub:$emoteSetId');
    super.unsubscribeEmoteSet(emoteSetId, owner: owner);
  }
}

class _Controller extends EmoteController {
  _Controller({
    required this.auth,
    required super.emoteManager,
    required super.sevenTvClient,
  }) : super(
         twitchApi: TwitchApi(),
         twitchAuth: auth,
         chat: Chat(),
         badgeService: TwitchBadgeService(),
         connectivityService: ConnectivityService(),
         signals: EmoteSignals(),
         getChannelUserIds: () => const {},
         applyAnimationsEnabled: (_) {},
         clearImageCache: () {},
       );

  final TwitchAuth auth;

  @override
  void primeForAccount() {
    emoteManager.viewerTwitchId = auth.userId;
    sevenTvClient.subscribeEmoteSet(
      'set-new',
      owner: SevenTvEmoteSetOwner.viewer(auth.userId ?? ''),
    );
  }

  @override
  Future<bool> refreshAfterAuth({
    bool force = false,
    void Function()? onFetchSettled,
    void Function()? onStep,
  }) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmoteMetaStore.I.reset();
  });

  test('account switch releases old viewer sets before new ones', () async {
    final client = _RecordingClient();
    final manager = EmoteManager(
      fetchStagger: Duration.zero,
      sevenTvOwnedSetIdsFetcher: (_) async => ['set-old'],
      sevenTvEmoteSetFetcher: (_) async => const [],
    );
    final auth = TwitchAuth()
      ..userId = 'v1'
      ..accessToken = 'token';
    final controller = _Controller(
      auth: auth,
      emoteManager: manager,
      sevenTvClient: client,
    );
    addTearDown(() {
      controller.dispose();
      manager.dispose();
      client.dispose();
    });

    manager.viewerTwitchId = 'v1';
    await manager.loadViewerPersonalSevenTvSets();
    client.subscribeEmoteSet(
      'set-old',
      owner: SevenTvEmoteSetOwner.viewer('v1'),
    );

    auth.userId = 'v2';
    await controller.onAccountChanged();

    expect(client.ops, [
      'sub:set-old',
      'unsub:set-old',
      'sub:set-new',
    ], reason: 'the old viewer owner is released before the new one arrives');
    expect(client.hasEmoteSetSubscription('set-old'), isFalse);
    expect(client.hasEmoteSetSubscription('set-new'), isTrue);
  });
}
