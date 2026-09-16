import 'dart:async';

import 'package:flutter/foundation.dart';

import '../emotes/emote.dart';
import '../util/log.dart';
import '../util/prefs.dart';

/// Provider visibility config: which third-party emote providers are fetched
/// and rendered, plus whether unlisted 7TV emotes render.
///
/// Owns the persisted prefs load/save and notifies on change. [EmoteManager]
/// mirrors the current snapshot into [EmoteStore]; the fetchers read the
/// enabled set at call time.
class EmoteVisibility extends ChangeNotifier {
  Prefs? _prefs;
  bool _loaded = false;
  bool _disposed = false;
  final Set<EmoteType> _disabled = {};
  bool _allowUnlisted = false;

  /// Disabled providers as an immutable snapshot.
  Set<EmoteType> get disabledProviders => Set.unmodifiable(_disabled);

  /// Whether unlisted 7TV emotes render.
  bool get allowUnlisted7tv => _allowUnlisted;

  /// Whether the persisted values have been read. [isProviderEnabled] and
  /// [allowUnlisted7tv] return the last-known value while the load is in
  /// flight, matching the previous lazy-load behavior.
  bool get isLoaded => _loaded;

  /// Whether [type] is fetched and rendered (sync view).
  bool isProviderEnabled(EmoteType type) {
    if (!_loaded) unawaited(ensureLoaded());
    return !_disabled.contains(type);
  }

  /// Current enabled providers, awaiting the persisted load first.
  Future<Set<EmoteType>> enabledProviders() async {
    await ensureLoaded();
    return {
      for (final t in EmoteType.values)
        if (!_disabled.contains(t)) t,
    };
  }

  /// Loads the persisted disabled set and unlisted flag once. Retries on
  /// failure instead of caching a failed load. Notifies listeners once loaded
  /// so the store snapshot refreshes.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await _getPrefs();
      final raw = prefs.emoteProvidersDisabled;
      var migrated = false;
      _disabled.clear();
      if (raw != null) {
        for (final t in EmoteType.values) {
          if (raw.contains(t.name)) _disabled.add(t);
        }
        // Migrate: Twitch is no longer toggleable.
        if (_disabled.remove(EmoteType.twitch)) migrated = true;
      }
      _allowUnlisted = prefs.emoteAllowUnlisted7tv;
      _notify();
      if (migrated) {
        await prefs.setEmoteProvidersDisabled(
          _disabled.map((t) => t.name).toList(),
        );
      }
    } catch (e) {
      // Retry on the next call instead of caching a failed load.
      _loaded = false;
      logDebug('[EmoteVisibility] failed to load provider visibility: $e');
    }
  }

  /// Toggles [type]; returns true when the enabled set actually changed.
  Future<bool> setProviderEnabled(EmoteType type, bool enabled) async {
    await ensureLoaded();
    final changed = enabled ? _disabled.remove(type) : _disabled.add(type);
    if (!changed) return false;
    final prefs = await _getPrefs();
    await prefs.setEmoteProvidersDisabled(
      _disabled.map((t) => t.name).toList(),
    );
    _notify();
    return true;
  }

  /// Sets unlisted 7TV rendering; returns true when the value changed.
  Future<bool> setAllowUnlisted(bool allowed) async {
    await ensureLoaded();
    if (allowed == _allowUnlisted) return false;
    _allowUnlisted = allowed;
    final prefs = await _getPrefs();
    await prefs.setEmoteAllowUnlisted7tv(allowed);
    _notify();
    return true;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<Prefs> _getPrefs() async {
    _prefs ??= await Prefs.load();
    return _prefs!;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
