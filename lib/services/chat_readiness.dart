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
  final _joinFailed = <String>{};
  bool _readEverConnected = false;
  bool _wasReadDisconnected = false;
  bool _everConnected = false;

  bool get pipeUp =>
      writeConnected() && (!_readEverConnected || readConnected());

  bool get everConnected => _everConnected;

  bool get readEverConnected => _readEverConnected;

  bool isChannelReady(String channel) {
    if (!readExpected() && !readConnected()) {
      return writeConnected() && _joinedChannels.contains(channel);
    }
    return _readJoinedChannels.contains(channel);
  }

  bool isJoinFailed(String channel) => _joinFailed.contains(channel);

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
    _joinFailed.clear();
    return true;
  }

  void resetForWriteDisconnect() {
    _connectedAcked.clear();
    _joinedChannels.clear();
  }

  bool acknowledgeConnected(String channel) => _connectedAcked.add(channel);

  /// Records a read ROOMSTATE: confirms the JOIN and clears any join failure,
  /// returning whether the channel was newly confirmed.
  bool noteReadRoomState(String channel) {
    final isNew = _readJoinedChannels.add(channel);
    if (isNew) _joinFailed.remove(channel);
    return isNew;
  }

  bool noteWriteRoomState(String channel) => _joinedChannels.add(channel);

  void noteJoinFailed(String channel) => _joinFailed.add(channel);

  void resetForAccountSwitch() {
    _joinedChannels.clear();
    _connectedAcked.clear();
  }

  /// Drops a channel's JOIN confirmations so a re-subscribe re-earns them.
  void forgetChannel(String channel) {
    _joinedChannels.remove(channel);
    _readJoinedChannels.remove(channel);
  }
}
