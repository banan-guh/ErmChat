import 'package:flutter/foundation.dart';

/// Change signal for persisted settings.
///
/// Values stay in `Prefs`; this only announces a write so owners re-read and
/// apply side effects. A global instance keeps settings tiles usable without
/// a ProviderScope in widget tests.
class PrefsStore extends ChangeNotifier {
  PrefsStore._();

  static final PrefsStore instance = PrefsStore._();

  /// Announces that a persisted setting changed; owners re-read `Prefs`.
  void notifyChanged() => notifyListeners();
}
