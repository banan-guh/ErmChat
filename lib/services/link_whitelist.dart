import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/constants.dart';

/// Whether a whitelist entry matches as a bare TLD (`lol` -> any `*.lol`) or a
/// full domain (`kappa.lol` -> that domain and its subdomains).
enum LinkType { tld, domain }

/// User-managed set of link suffixes used to rejoin and linkify *fractured*
/// (spaced) domains — the anti-evasion case where a link is typed with a space
/// to dodge a "no links" filter (e.g. `kappa .lol`, `kappa. lol/ABCDE`). Plain
/// `kappa.lol` (no space) is handled by linkify's own default, not here.
///
/// Shared app-wide singleton (mirrors [IgnoreManager]): the live pipeline and
/// the settings screen both read/write the same instance.
class LinkWhitelist extends ChangeNotifier {
  static final LinkWhitelist instance = LinkWhitelist();

  static const List<String> _defaults = [
    'kappa.lol',
    'gachi.gay',
    'i.nuuls.com',
    'youtu.be',
  ];

  /// The seeded default entries, exposed so the settings UI can offer a
  /// "restore defaults" action.
  static List<String> get defaultEntries => List.of(_defaults);

  List<String> _entries = const [];
  bool _loaded = false;
  bool enabled = false;

  bool get loaded => _loaded;
  List<String> get entries => List.unmodifiable(_entries);

  /// Strips whitespace and any leading/trailing dots so ` .lol ` and `lol.`
  /// normalize to `lol`.
  static String normalize(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '').trim();

  static LinkType classify(String entry) =>
      entry.contains('.') ? LinkType.domain : LinkType.tld;

  static const String _enabledKey = 'link_whitelist_enabled';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(kLinkWhitelistPrefKey);
    if (stored == null) {
      // First run: seed the defaults so the feature works out of the box.
      _entries = List.of(_defaults);
      await _persist();
    } else {
      _entries = stored;
    }
    enabled = prefs.getBool(_enabledKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(kLinkWhitelistPrefKey, _entries);
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
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

  /// Replaces the current list with the seeded defaults.
  void restoreDefaults() {
    _entries = List.of(_defaults);
    unawaited(_persist());
    notifyListeners();
  }
}
