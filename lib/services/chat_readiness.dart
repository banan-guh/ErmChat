import '../util/fake_history.dart';

/// Join-confirmation and read-socket-health state. Owns the per-channel
/// readiness sets and outage flags, answering the manager's readiness
/// queries through injected connection predicates.
class ChatReadiness {
  ChatReadiness({
    required this.writeConnected,
    required this.readConnected,
    required this.readExpected,
  });

  final bool Function() writeConnected;
  final bool Function() readConnected;
  final bool Function() readExpected;

  final _connectedAcked = <String>{};
  // Write-socket JOIN confirmations. In production the write socket never
  // JOINs, so this stays empty; it exists so tests that drive ROOMSTATE
  // through the write socket still resolve readiness. The read socket's JOIN
  // is the real production signal.
  final _joinedChannels = <String>{};
  // Channels the read socket has JOINed (confirmed by ROOMSTATE). The write
  // socket never JOINs, so this is the authoritative readiness source: a
  // fresh or reconnected read socket may not have processed its JOINs yet,
  // and the local echo of our own messages rides it.
  final _readJoinedChannels = <String>{};
  // Channels whose JOIN timed out or was refused on the read socket. They
  // stop counting as loading until a ROOMSTATE confirms them.
  final _joinFailedChannels = <String>{};
  bool _readEverConnected = false;
  bool _wasReadDisconnected = false;
  bool _everConnected = false;

  bool get pipeUp =>
      writeConnected() && (!_readEverConnected || readConnected());

  bool get everConnected => _everConnected;

  bool get readEverConnected => _readEverConnected;

  bool isChannelReady(String channel) {
    // Prototype channels never JOIN, so they are ready by construction.
    if (FakeHistory.isFake(channel)) return true;
    if (!readExpected() && !readConnected()) {
      return writeConnected() && _joinedChannels.contains(channel);
    }
    return _readJoinedChannels.contains(channel);
  }

  /// Whether the channel's JOIN gave up waiting and is still unconfirmed.
  bool isJoinFailed(String channel) => _joinFailedChannels.contains(channel);

  /// Records an unconfirmed or refused JOIN; true when newly recorded.
  bool noteJoinFailed(String channel) => _joinFailedChannels.add(channel);

  void noteWriteSocketConnected() => _everConnected = true;

  void noteReadSocketEverConnected() => _readEverConnected = true;

  /// Records a read-socket recovery; true when this ends an outage.
  bool noteReadSocketRecovered() {
    if (!_wasReadDisconnected) return false;
    _wasReadDisconnected = false;
    return true;
  }

  /// Records a read-socket outage; true when this starts a new outage.
  bool noteReadSocketDisconnected() {
    if (_wasReadDisconnected) return false;
    _wasReadDisconnected = true;
    _connectedAcked.clear();
    _readJoinedChannels.clear();
    _joinFailedChannels.clear();
    return true;
  }

  void resetForWriteDisconnect() {
    _connectedAcked.clear();
    _joinedChannels.clear();
  }

  bool acknowledgeConnected(String channel) => _connectedAcked.add(channel);

  /// Records a read ROOMSTATE: confirms the JOIN, returning whether the
  /// channel was newly confirmed.
  bool noteReadRoomState(String channel) {
    _joinFailedChannels.remove(channel);
    return _readJoinedChannels.add(channel);
  }

  bool noteWriteRoomState(String channel) => _joinedChannels.add(channel);

  void resetForAccountSwitch() {
    _joinedChannels.clear();
    _readJoinedChannels.clear();
    _connectedAcked.clear();
    _joinFailedChannels.clear();
  }

  /// Drops a channel's JOIN confirmations so a re-subscribe re-earns them.
  void forgetChannel(String channel) {
    _joinedChannels.remove(channel);
    _readJoinedChannels.remove(channel);
    _joinFailedChannels.remove(channel);
  }
}
