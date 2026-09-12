import 'dart:async';

import 'package:flutter/material.dart';

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

  /// Default entries for "restore defaults" UI.
  static List<String> get defaultEntries => List.of(_defaults);

  List<String> _entries = const [];
  bool _loaded = false;
  bool enabled = false;

  bool get loaded => _loaded;
  List<String> get entries => List.unmodifiable(_entries);

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
      _entries = List.of(_defaults);
      await _persist();
    } else {
      _entries = stored;
    }
    enabled = prefs.linkWhitelistEnabled;
    _loaded = true;
    notifyListeners();
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
    notifyListeners();
  }

  void add(String raw) {
    final entry = normalize(raw);
    if (entry.isEmpty || _entries.contains(entry)) return;
    _entries = [..._entries, entry];
    unawaited(_persist());
    notifyListeners();
  }

  void remove(String entry) {
    final normalized = normalize(entry);
    if (!_entries.contains(normalized)) return;
    _entries = _entries.where((e) => e != normalized).toList();
    unawaited(_persist());
    notifyListeners();
  }

  /// Resets to default entries.
  void restoreDefaults() {
    _entries = List.of(_defaults);
    unawaited(_persist());
    notifyListeners();
  }
}
