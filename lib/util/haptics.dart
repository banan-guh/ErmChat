import 'package:flutter/services.dart';

import 'settings.dart';

/// The app's haptics, named by meaning, on every platform. Widgets that
/// fire one turn off their own system feedback so it never doubles.
abstract final class Haptics {
  /// A value changed: slider steps, picked options, crossed thresholds.
  static void select() => _fire(HapticFeedback.selectionClick);

  /// A gesture took effect: a menu opened, a drag picked up or dropped.
  static void press() => _fire(HapticFeedback.lightImpact);

  /// Something destructive or major happened: a removal, a spam run.
  static void major() => _fire(HapticFeedback.mediumImpact);

  static void _fire(Future<void> Function() fire) {
    if (Settings.haptics.value) fire();
  }
}
