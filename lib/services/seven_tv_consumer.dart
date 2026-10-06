import 'dart:async';

import '../l10n/l10n.dart';
import '../emotes/emote.dart';
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
    this.strings = englishStrings,
  });

  final AppLocalizations Function() strings;

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
            .whereType<Emote>()
            .toList(),
        removedIds: event.removed.map((e) => e.id).toList(),
        renamed: {for (final r in event.renamed) r.id: r.newName},
      );
      return;
    }

    final added = event.added
        .map((e) => SevenTvEmoteProvider.parseSingleEmote(e.raw, channel: true))
        .whereType<Emote>()
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

    final l = strings();
    final actor = event.actor ?? l.sevenTvSomeUser;
    for (final e in event.added) {
      onSystemMessage(channel, l.sevenTvEmoteAdded(actor, e.name));
    }
    for (final e in event.removed) {
      onSystemMessage(channel, l.sevenTvEmoteRemoved(actor, e.name));
    }
    for (final e in event.renamed) {
      onSystemMessage(
        channel,
        l.sevenTvEmoteRenamed(actor, e.oldName, e.newName),
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

    final l = strings();
    onSystemMessage(
      channel,
      l.sevenTvSetSwitched(event.actor ?? l.sevenTvSomeUser),
    );
  }
}
