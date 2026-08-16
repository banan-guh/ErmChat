import 'package:flutter/foundation.dart';

/// Whether app-level debug logging is enabled.
///
/// Tests set this to false (via `test/flutter_test_config.dart`) to keep the
/// test console readable. The Flutter test binding forces [debugPrint] to a
/// synchronous console printer, so silencing has to happen at this hook.
bool debugLogEnabled = true;

/// App logging hook. Call this instead of [debugPrint] so the test suite can
/// silence chat-pipeline noise (IRC joins, badge fetch failures, reconnect
/// diagnostics) without touching the binding's [debugPrint] plumbing.
void logDebug(String? message, {int? wrapWidth}) {
  if (debugLogEnabled) {
    debugPrint(message, wrapWidth: wrapWidth);
  }
}
