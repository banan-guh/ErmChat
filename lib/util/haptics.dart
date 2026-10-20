import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// The app's haptics, named by meaning. [iosOnly] fires on iOS only.
abstract final class Haptics {
  /// A value changed: slider steps, picked options, crossed thresholds.
  static void select({bool iosOnly = false}) =>
      _fire(HapticFeedback.selectionClick, iosOnly);

  /// A gesture took effect: a menu opened, a drag picked up or dropped.
  static void press({bool iosOnly = false}) =>
      _fire(HapticFeedback.lightImpact, iosOnly);

  /// Something destructive or major happened: a removal, a spam run.
  static void major({bool iosOnly = false}) =>
      _fire(HapticFeedback.mediumImpact, iosOnly);

  static void _fire(Future<void> Function() fire, bool iosOnly) {
    if (iosOnly && (kIsWeb || !Platform.isIOS)) return;
    fire();
  }
}
