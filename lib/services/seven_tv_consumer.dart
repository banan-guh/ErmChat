import 'dart:async';

import '../models/generic_emote.dart';
import 'emote_manager.dart';
import 'emote_providers/seven_tv_emotes.dart';
import 'seven_tv_event_client.dart';

/// Applies 7TV socket events to the emote manager: live emote-set edits,
/// active-set switches, and foreign personal-set tracking.
class SevenTvConsumer {
  SevenTvConsumer({
    required this.emoteManager,
    required this.sevenTvClient,
    required this.onSystemMessage,
  });

  final EmoteManager emoteManager;
  final SevenTvEventClient? sevenTvClient;
  final void Function(String channel, String text) onSystemMessage;

  bool _disposed = false;
  final _subscriptions = <StreamSubscription>[];

  /// Subscribes the three 7TV streams and returns the subscriptions.
  /// Re-attaching cancels the previous subscriptions first. A null client
  /// subscribes nothing.
  List<StreamSubscription> attach() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    final client = sevenTvClient;
    if (client == null) return List.unmodifiable(_subscriptions);
    _subscriptions
      ..add(client.onEmoteSetUpdate.listen(_onEmoteSetUpdate))
      ..add(client.onUserUpdate.listen(_onUserUpdate))
      ..add(
        client.onPersonalSet.listen((event) {
          if (_disposed) return;
          emoteManager.trackForeignPersonalSet(event.setId);
        }),
      );
    return List.unmodifiable(_subscriptions);
  }

  void dispose() {
    _disposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  void _onEmoteSetUpdate(SevenTvEmoteUpdateEvent event) {
    if (_disposed) return;
    final channel = emoteManager.getChannelForSevenTvEmoteSet(event.emoteSetId);
    if (channel == null) {
      // Foreign personal set (or untracked): contents only matter with a
      // grant mapping, which the manager checks before applying.
      emoteManager.applyForeignPersonalSetUpdate(
        setId: event.emoteSetId,
        added: event.added
            .map(
              (e) =>
                  SevenTvEmoteProvider.parseSingleEmote(e.raw, personal: true),
            )
            .whereType<GenericEmote>()
            .toList(),
        removedIds: event.removed.map((e) => e.id).toList(),
        renamed: {for (final r in event.renamed) r.id: r.newName},
      );
      return;
    }

    final added = event.added
        .map((e) => SevenTvEmoteProvider.parseSingleEmote(e.raw, channel: true))
        .whereType<GenericEmote>()
        .toList();
    final removedIds = event.removed.map((e) => e.id).toList();
    final renamed = <String, ({String newName, String oldName})>{};
    for (final r in event.renamed) {
      renamed[r.id] = (newName: r.newName, oldName: r.oldName);
    }

    emoteManager.updateSevenTvEmotes(
      channel,
      added: added,
      removedIds: removedIds,
      renamed: renamed,
    );

    final actor = event.actor ?? 'A user';
    for (final e in event.added) {
      onSystemMessage(channel, '$actor added 7TV Emote ${e.name}.');
    }
    for (final e in event.removed) {
      onSystemMessage(channel, '$actor removed 7TV Emote ${e.name}.');
    }
    for (final e in event.renamed) {
      onSystemMessage(
        channel,
        '$actor renamed 7TV Emote ${e.oldName} to ${e.newName}.',
      );
    }
  }

  void _onUserUpdate(SevenTvUserUpdate event) {
    if (_disposed) return;
    final channel = emoteManager.getChannelForSevenTvEmoteSet(
      event.oldEmoteSetId,
    );
    if (channel == null) return;
    if (event.oldEmoteSetId.isNotEmpty) {
      sevenTvClient?.unsubscribeEmoteSet(event.oldEmoteSetId);
    }
    sevenTvClient?.subscribeEmoteSet(event.newEmoteSetId);
    emoteManager.setSevenTvEmoteSetId(channel, event.newEmoteSetId);
    // Pull the new set's contents: subscribing alone leaves the old set
    // rendering until restart.
    unawaited(emoteManager.reconcileSevenTvChannel(channel));

    final actor = event.actor ?? 'A user';
    onSystemMessage(channel, '$actor switched the active 7TV Emote Set.');
  }
}
