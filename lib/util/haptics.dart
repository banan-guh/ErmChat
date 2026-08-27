import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Fires [fire] only on physical iOS devices. Other platforms (and the web)
/// are silent no-ops, so callers can request feedback freely without
/// branching on platform themselves.
void iosHaptic(void Function() fire) {
  if (!kIsWeb && Platform.isIOS) fire();
}
