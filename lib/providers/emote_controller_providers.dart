import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_controller.dart';
import '../util/signal.dart';
import 'app_providers.dart';
import 'feature_providers.dart';

/// Provider-owned output ports the emote controller pushes at the shell.
final emoteSignalsProvider = Provider<EmoteSignals>((ref) {
  final signals = EmoteSignals();
  ref.onDispose(signals.dispose);
  return signals;
});

/// App-scope emote daemon control (tier/auto/cache prefs, post-auth refresh,
/// manual reload/nuke) plus the emote lifecycle (boot priming, cache GC, and
/// the 7TV entitlement stream). Owns the entitlement listener; teardown
/// cancels it.
final emoteControllerProvider = Provider<EmoteController>((ref) {
  final controller = EmoteController(
    emoteManager: ref.read(emoteManagerProvider),
    twitchApi: ref.read(twitchApiProvider),
    twitchAuth: ref.read(twitchAuthProvider),
    chat: ref.read(chatProvider),
    badgeService: ref.read(badgeServiceProvider),
    connectivityService: ref.read(connectivityServiceProvider),
    signals: ref.read(emoteSignalsProvider),
    getChannelUserIds: ref.read(channelUserIdsProvider),
    sevenTvClient: ref.read(sevenTvClientProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
