import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emote_store.dart';

/// Snapshot of the emote catalog version plus the change that produced it.
/// [change] is null only for the initial state.
class EmoteState {
  const EmoteState(this.version, this.change);

  final int version;
  final EmoteChange? change;
}

final emoteStoreProvider = Provider<EmoteStore>((ref) {
  final store = EmoteStore();
  ref.onDispose(store.dispose);
  return store;
});

/// Bridges the store's typed [EmoteChange] stream to Riverpod so widgets
/// observe it with `ref.listen` instead of a manual listener. The store owns
/// no resources beyond its listener list, so teardown just detaches.
class EmoteStoreNotifier extends Notifier<EmoteState> {
  @override
  EmoteState build() {
    final store = ref.watch(emoteStoreProvider);
    void onChange(EmoteChange change) {
      state = EmoteState(store.version, change);
    }

    store.addListener(onChange);
    ref.onDispose(() => store.removeListener(onChange));
    return EmoteState(store.version, store.lastChange);
  }
}

final emoteStateProvider = NotifierProvider<EmoteStoreNotifier, EmoteState>(
  EmoteStoreNotifier.new,
);
