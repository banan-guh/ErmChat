import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/prefs.dart';

/// Bare TLD (any `*.lol`) or full domain (`kappa.lol` + subs).
enum LinkType { tld, domain }

/// Rejoins fractured (spaced) domains to dodge "no links" filters.
class LinkWhitelist extends ChangeNotifier {
  static final LinkWhitelist instance = LinkWhitelist();

  static const List<String> _defaults = [
    'kappa.lol',
    'gachi.gay',
    'i.nuuls.com',
    'youtu.be',
  ];

  // Always unmodifiable and replaced on change, so [entries] hands it out
  // without a copy.
  List<String> _entries = const [];
  bool _loaded = false;
  bool enabled = false;
  int _revision = 0;

  bool get loaded => _loaded;
  List<String> get entries => _entries;

  /// Bumped on every change, so render caches can key on one int.
  int get revision => _revision;

  /// Normalizes entry: strips whitespace and leading/trailing dots.
  static String normalize(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '').trim();

  static LinkType classify(String entry) =>
      entry.contains('.') ? LinkType.domain : LinkType.tld;

  Future<void> load() async {
    final prefs = await Prefs.load();
    final stored = prefs.linkWhitelist;
    if (stored == null) {
      // First run: seed defaults.
      _entries = List.unmodifiable(_defaults);
      await _persist();
    } else {
      _entries = List.unmodifiable(stored);
    }
    enabled = prefs.linkWhitelistEnabled;
    _loaded = true;
    _changed();
  }

  Future<void> _persist() async {
    final prefs = await Prefs.load();
    await prefs.setLinkWhitelist(_entries);
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    final prefs = await Prefs.load();
    await prefs.setLinkWhitelistEnabled(value);
    _changed();
  }

  void add(String raw) {
    final entry = normalize(raw);
    if (entry.isEmpty || _entries.contains(entry)) return;
    _entries = List.unmodifiable([..._entries, entry]);
    unawaited(_persist());
    _changed();
  }

  void remove(String entry) {
    final normalized = normalize(entry);
    if (!_entries.contains(normalized)) return;
    _entries = List.unmodifiable(_entries.where((e) => e != normalized));
    unawaited(_persist());
    _changed();
  }

  /// Resets to default entries.
  void restoreDefaults() {
    _entries = List.unmodifiable(_defaults);
    unawaited(_persist());
    _changed();
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }
}
