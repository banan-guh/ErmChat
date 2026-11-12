import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/constants.dart';
import '../util/prefs.dart';
import '../util/settings.dart';

/// Hosts whose short links serve raw images without a file extension.
/// Seeded from [kImageEmbedHosts] and editable in Inline embeds > Image hosts.
class ImageEmbedHosts extends ChangeNotifier {
  static final ImageEmbedHosts instance = ImageEmbedHosts();

  // Always unmodifiable and replaced on change, so [entries] hands it out
  // without a copy.
  List<String> _entries = const [];
  bool _loaded = false;
  int _revision = 0;

  bool get loaded => _loaded;
  List<String> get entries => _entries;

  /// [entries] once loaded, else the built-in defaults, so a render before
  /// the first load still previews the usual hosts.
  List<String> get resolvedEntries => _loaded ? _entries : kImageEmbedHosts;

  /// Bumped on every change, so render caches can key on one int.
  int get revision => _revision;

  /// Host only: drops a scheme, path, whitespace and leading/trailing dots.
  static String normalize(String raw) {
    var value = raw.trim().toLowerCase();
    final uri = Uri.tryParse(value);
    if (uri != null && uri.host.isNotEmpty) {
      value = uri.host;
    } else {
      value = value.split('/').first;
    }
    return value
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'^\.+|\.+$'), '')
        .trim();
  }

  Future<void> load() async {
    await Prefs.load();
    final stored = Settings.imageEmbedHosts.value;
    if (stored == null) {
      // First run: seed defaults.
      _entries = List.unmodifiable(kImageEmbedHosts);
      await _persist();
    } else {
      _entries = List.unmodifiable(stored);
    }
    _loaded = true;
    _changed();
  }

  Future<void> _persist() async {
    await Prefs.load();
    await Settings.imageEmbedHosts.set(_entries);
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

  void restoreDefaults() {
    _entries = List.unmodifiable(kImageEmbedHosts);
    unawaited(_persist());
    _changed();
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }
}
