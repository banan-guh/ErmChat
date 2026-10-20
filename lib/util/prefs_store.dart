import 'package:flutter/foundation.dart';

import 'settings.dart';

/// Bulk change signal for persisted settings.
///
/// Each [Settings] entry notifies its own listeners on write; prefer those.
/// This announces writes that bypass them (imports, raw store writes) and
/// wakes owners that re-read everything. A global instance keeps settings
/// tiles usable without a ProviderScope in widget tests.
class PrefsStore extends ChangeNotifier {
  PrefsStore._();

  static final PrefsStore instance = PrefsStore._();

  /// Announces that persisted settings changed: each changed [Settings]
  /// entry notifies, then owners that re-read `Prefs` wake.
  void notifyChanged() {
    Settings.refresh();
    notifyListeners();
  }
}
