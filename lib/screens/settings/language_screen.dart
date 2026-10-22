import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../util/settings.dart';
import 'settings_page.dart';

/// App language: the system default or any shipped translation. Saving
/// switches the whole app at runtime.
class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  /// Saved language tag; empty follows the system.
  String get _locale => Settings.locale.value ?? '';

  Future<void> _select(String tag) async {
    if (tag == _locale) return;
    await Settings.locale.set(tag.isEmpty ? null : tag);
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
      body: ValueListenableBuilder<String?>(
        valueListenable: Settings.locale,
        builder: (context, locale, _) => ListView(
          children: [
            for (final tag in ['', ..._localeTags])
              ListTile(
                title: Text(
                  tag.isEmpty
                      ? context.l10n.languageSystem
                      : _languageName(tag),
                ),
                trailing: tag == (locale ?? '')
                    ? Icon(Icons.check, color: primary)
                    : null,
                onTap: () => _select(tag),
              ),
          ],
        ),
      ),
    );
  }
}
