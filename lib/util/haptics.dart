import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Fires haptic on iOS only; other platforms are no-ops.
void iosHaptic(void Function() fire) {
  if (!kIsWeb && Platform.isIOS) fire();
}
