import 'package:flutter/foundation.dart';

/// Per-channel status and load state. Drops with the channel.
///
/// [version] covers structural reads (broadcaster id, history state, load
/// failures): listeners may drop cached tiles on it. [statusVersion] covers
/// the free-text status splash only, which ticks every 30s on live channels
/// (viewer counts) and must never drop tiles by itself.
class ChannelInfo {
  final ValueNotifier<int> version = ValueNotifier(0);
  final ValueNotifier<int> statusVersion = ValueNotifier(0);

  String _stream = '';
  List<String> _modes = const [];
  bool _isLive = false;
  String? _broadcasterId;
  bool _historyLoaded = false;

  /// The full status line: room [modes] then the [stream] part.
  String get status => [..._modes, if (_stream.isNotEmpty) _stream].join(' · ');

  /// Short room mode labels ("Slow (30s)", "Subs").
  List<String> get modes => _modes;

  /// The stream part ("Live with … viewers"), empty when offline.
  String get stream => _stream;

  /// Whether the stream is live, set alongside the display [status].
  bool get isLive => _isLive;
  String? get broadcasterId => _broadcasterId;
  bool get historyLoaded => _historyLoaded;

  final Set<String> _loadFailures = {};

  bool get hasLoadFailure => _loadFailures.isNotEmpty;

  Set<String> failures() => Set.of(_loadFailures);

  void setStatus(
    String stream, {
    bool live = false,
    List<String> modes = const [],
  }) {
    if (_stream == stream && _isLive == live && listEquals(_modes, modes)) {
      return;
    }
    _stream = stream;
    _modes = List.unmodifiable(modes);
    _isLive = live;
    statusVersion.value++;
  }

  void setBroadcasterId(String? id) {
    if (_broadcasterId == id) return;
    _broadcasterId = id;
    version.value++;
  }

  void setHistoryLoaded(bool loaded) {
    if (_historyLoaded == loaded) return;
    _historyLoaded = loaded;
    version.value++;
  }

  void recordLoadFailure(String kind) {
    if (_loadFailures.add(kind)) version.value++;
  }

  void clearLoadFailure([String? kind]) {
    if (kind != null) {
      if (_loadFailures.remove(kind)) version.value++;
      return;
    }
    if (_loadFailures.isEmpty) return;
    _loadFailures.clear();
    version.value++;
  }

  /// Ticks render epoch without changing data (settings rerender path).
  void touch() => version.value++;

  void dispose() {
    version.dispose();
    statusVersion.dispose();
    _loadFailures.clear();
  }
}
