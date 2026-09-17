import 'dart:async';

import '../chat/chat.dart';
import '../color_utils.dart' show Color;
import '../models/point_rewards.dart';
import '../models/twitch_message.dart';
import '../util/log.dart';
import 'pubsub_points_service.dart';

/// Joins PubSub redemption banners to IRC chat lines, mirroring DankChat.
///
/// Two arrivals, either order:
/// - PubSub first: park input-required redemptions keyed by reward id.
/// - IRC first: [ChatIngestion] records the waiting chat line; a later
///   PubSub partner retro-inserts the header above it via the channel verb.
/// No-input redemptions have no IRC partner and post standalone.
/// Silent on failure: a missing partner just leaves the highlighted chat
/// line (or nothing), never an error row.
class PubSubPointsConsumer {
  PubSubPointsConsumer({
    required this.chat,
    required this.getMaxMessages,
    this.clock,
  });

  final Chat chat;
  final int Function() getMaxMessages;
  final DateTime Function()? clock;

  DateTime _now() => clock?.call() ?? DateTime.now();

  /// Staged input-required redemptions by `channel\x00rewardId`.
  final _staged = <String, List<_StagedRedemption>>{};

  /// IRC chat lines still awaiting their PubSub partner, same keying.
  final _waitingIrc = <String, List<_WaitingIrc>>{};

  static const _partnerTtl = Duration(seconds: 10);
  static const _maxStagedPerKey = 5;

  StreamSubscription<PubSubPointRedemption>? _sub;
  bool _disposed = false;

  /// Subscribes the redemption stream. Re-attaching cancels first.
  void attach(Stream<PubSubPointRedemption> source) {
    _sub?.cancel();
    _sub = source.listen(_onRedemption);
  }

  /// Takes a staged partner for an incoming IRC redeem, oldest first.
  PointRedemption? takeStaged(String channel, String rewardId) {
    if (_disposed) return null;
    final key = _key(channel, rewardId);
    final queue = _staged[key];
    if (queue == null || queue.isEmpty) return null;
    _prune(queue, _now());
    if (queue.isEmpty) {
      _staged.remove(key);
      return null;
    }
    final staged = queue.removeAt(0);
    if (queue.isEmpty) _staged.remove(key);
    return staged.redemption;
  }

  /// Records an IRC redeem line that found no staged partner yet.
  void noteIrcRedemption(String channel, String rewardId, String? messageId) {
    if (_disposed || messageId == null || messageId.isEmpty) return;
    final key = _key(channel, rewardId);
    final queue = _waitingIrc.putIfAbsent(key, () => []);
    if (queue.any((w) => w.messageId == messageId)) return;
    queue.add(_WaitingIrc(messageId: messageId, at: _now()));
    _prune(queue, _now());
    if (queue.isEmpty) {
      _waitingIrc.remove(key);
    } else if (queue.length > _maxStagedPerKey) {
      queue.removeRange(0, queue.length - _maxStagedPerKey);
    }
  }

  void _onRedemption(PubSubPointRedemption event) {
    if (_disposed) return;
    final redemption = event.redemption;
    if (redemption.rewardId.isEmpty) {
      // Unkeyable: only a standalone header makes sense.
      if (redemption.requiresUserInput) return;
      _postStandalone(event.channel, redemption);
      return;
    }
    if (redemption.requiresUserInput) {
      final key = _key(event.channel, redemption.rewardId);
      final waiting = _waitingIrc[key];
      if (waiting != null && waiting.isNotEmpty) {
        _prune(waiting, _now());
        if (waiting.isNotEmpty) {
          final target = waiting.removeAt(0);
          if (waiting.isEmpty) _waitingIrc.remove(key);
          if (_retroInsert(event.channel, target.messageId, redemption)) {
            return;
          }
        } else {
          _waitingIrc.remove(key);
        }
      }
      final queue = _staged.putIfAbsent(key, () => []);
      queue.add(_StagedRedemption(redemption: redemption, at: _now()));
      _prune(queue, _now());
      if (queue.length > _maxStagedPerKey) {
        queue.removeRange(0, queue.length - _maxStagedPerKey);
      }
      if (queue.isEmpty) _staged.remove(key);
    } else {
      _postStandalone(event.channel, redemption);
    }
  }

  /// Posts the companion header for an IRC redeem whose partner was staged.
  /// Called before the chat line itself is received, so display order reads
  /// header above message. Returns whether the header went in.
  bool insertCompanionHeader(String channel, PointRedemption redemption) {
    final header = _headerMessage(channel, redemption, withUser: false);
    final target = chat.channelFor(channel);
    if (target == null) return false;
    final result = chat.receive(
      channel,
      header,
      maxMessages: getMaxMessages(),
      isSelected: true,
      ownLogin: null,
    );
    return result.inserted;
  }

  void _postStandalone(String channel, PointRedemption redemption) {
    final header = _headerMessage(channel, redemption, withUser: true);
    final target = chat.channelFor(channel);
    if (target == null) {
      logDebug('PubSub points: no channel $channel for standalone header');
      return;
    }
    chat.receive(
      channel,
      header,
      maxMessages: getMaxMessages(),
      isSelected: true,
      ownLogin: null,
    );
  }

  bool _retroInsert(
    String channel,
    String targetMessageId,
    PointRedemption redemption,
  ) {
    final header = _headerMessage(channel, redemption, withUser: false);
    final target = chat.channelFor(channel);
    if (target == null) return false;
    return target.insertHeaderAbove(
      targetMessageId,
      header,
      maxMessages: getMaxMessages(),
    );
  }

  /// Builds the header row. Input-required headers omit the user because the
  /// chat line right below already shows who said what (DankChat parity).
  TwitchMessage _headerMessage(
    String channel,
    PointRedemption redemption, {
    required bool withUser,
  }) {
    final title = redemption.rewardTitle.isNotEmpty
        ? redemption.rewardTitle
        : 'channel reward';
    final cost = redemption.cost > 0 ? ' (${redemption.cost} pts)' : '';
    final text = withUser
        ? '${_displayName(redemption)} redeemed $title$cost'
        : 'Redeemed $title$cost';
    final id = redemption.id.isNotEmpty
        ? 'redemp:${redemption.id}'
        : 'redemp:${redemption.rewardId}:${redemption.redeemedAt}';
    DateTime? timestamp;
    if (redemption.redeemedAt.isNotEmpty) {
      timestamp = DateTime.tryParse(redemption.redeemedAt)?.toLocal();
    }
    return TwitchMessage(
      login: '',
      text: text,
      isSystem: true,
      systemAccent: _redemptionAccent,
      messageId: id,
      channel: channel,
      timestamp: timestamp,
      redemptionImageUrl: redemption.imageUrl,
    );
  }

  static String _displayName(PointRedemption redemption) {
    if (redemption.userDisplayName.isNotEmpty) {
      return redemption.userDisplayName;
    }
    return redemption.userLogin.isNotEmpty ? redemption.userLogin : 'Someone';
  }

  static String _key(String channel, String rewardId) =>
      '$channel\x00$rewardId';

  static void _prune(List<_Expiring> queue, DateTime now) {
    queue.removeWhere((e) => now.difference(e.at) > _partnerTtl);
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _staged.clear();
    _waitingIrc.clear();
  }

  // Redemption teal from the highlight palette; the tile equalizes it
  // against the surface, so one base serves both themes.
  static const _redemptionAccent = Color(0xFF00606B);
}

abstract class _Expiring {
  DateTime get at;
}

class _StagedRedemption implements _Expiring {
  _StagedRedemption({required this.redemption, required this.at});

  final PointRedemption redemption;
  @override
  final DateTime at;
}

class _WaitingIrc implements _Expiring {
  _WaitingIrc({required this.messageId, required this.at});

  final String messageId;
  @override
  final DateTime at;
}
