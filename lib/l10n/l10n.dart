import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

extension L10nContext on BuildContext {
  /// Strings for the app's current locale. English when no localizations
  /// are installed above (bare test harnesses).
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      englishStrings();
}

/// English strings for callers with no context or injected strings (tests,
/// bare services). Lives here so non-UI layers need no Flutter import.
AppLocalizations englishStrings() => lookupAppLocalizations(const Locale('en'));
