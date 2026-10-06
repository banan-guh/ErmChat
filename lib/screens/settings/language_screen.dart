import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../util/prefs.dart';
import '../../util/prefs_store.dart';
import 'settings_page.dart';

/// App language: the system default or any shipped translation. Saving
/// switches the whole app at runtime.
class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  Prefs? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    PrefsStore.instance.addListener(_loadPrefs);
  }

  @override
  void dispose() {
    PrefsStore.instance.removeListener(_loadPrefs);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await Prefs.load();
    if (mounted) setState(() => _prefs = prefs);
  }

  /// Saved language tag; empty follows the system.
  String get _locale => _prefs?.locale ?? '';

  Future<void> _select(String tag) async {
    if (tag == _locale) return;
    final prefs = _prefs ?? await Prefs.load();
    await prefs.setLocale(tag.isEmpty ? null : tag);
    PrefsStore.instance.notifyChanged();
    if (mounted) setState(() {});
  }

  /// Every shipped translation, as `pt_BR` style tags.
  static final _localeTags = [
    for (final l in AppLocalizations.supportedLocales)
      [l.languageCode, ?l.countryCode].join('_'),
  ];

  /// Each language in its own words, so a reader finds theirs.
  static String _languageName(String tag) => switch (tag) {
    'en' => 'English',
    'es' => 'Español',
    'de' => 'Deutsch',
    'fr' => 'Français',
    'pt' || 'pt_BR' => 'Português',
    'ja' => '日本語',
    _ => tag,
  };

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SettingsPage(
      title: Text(context.l10n.settingLanguage),
      body: ListView(
        children: [
          for (final tag in ['', ..._localeTags])
            ListTile(
              title: Text(
                tag.isEmpty ? context.l10n.languageSystem : _languageName(tag),
              ),
              trailing: tag == _locale
                  ? Icon(Icons.check, color: primary)
                  : null,
              onTap: () => _select(tag),
            ),
        ],
      ),
    );
  }
}
