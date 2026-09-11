import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Shared connectivity state so every consumer (IRC sockets, EventSub, 7TV,
/// emote tiering) reacts to the same probe instead of each holding its own
/// plugin instance.
///
/// Seeded optimistically as online (plus_plugins#2527: the plugin sometimes
/// reports an empty result set on cold start), then corrected by [init] and
/// subsequent events. Consumers therefore never see a false "offline" window
/// at launch.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  // Optimistic default: online until the plugin reports otherwise.
  List<ConnectivityResult> _results = const [ConnectivityResult.wifi];

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _started = false;

  List<ConnectivityResult> get results => _results;
  bool get isOnline => !_results.contains(ConnectivityResult.none);
  bool get isMobile => _results.contains(ConnectivityResult.mobile);

  /// Seeds the initial state from the plugin and starts listening. Safe to
  /// call repeatedly; errors keep the optimistic default and are corrected by
  /// the first real connectivity event.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      final results = await _connectivity.checkConnectivity();
      _setResults(results);
    } catch (e) {
      // Keep the online default; a later event corrects it.
    }
    try {
      _sub ??= _connectivity.onConnectivityChanged.listen(_setResults);
    } catch (e) {
      // No platform stream (tests/unsupported): the seeded state stands.
    }
  }

  /// Live probe, used where a fresh answer is wanted (e.g. emote tiering).
  Future<List<ConnectivityResult>> checkConnectivity() =>
      _connectivity.checkConnectivity();

  void _setResults(List<ConnectivityResult> results) {
    // plus_plugins#2527: an empty report means "unknown", not "offline".
    if (results.isEmpty) return;
    _results = List.unmodifiable(results);
    notifyListeners();
  }

  @visibleForTesting
  void debugSetResults(List<ConnectivityResult> results) =>
      _setResults(results);

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
