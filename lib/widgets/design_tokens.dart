import 'package:flutter/animation.dart';

/// The app's motion scale. Every UI animation picks one duration and one
/// curve from here; timers, debounces and gesture thresholds are not motion
/// and keep their own values.
abstract final class Motion {
  /// Fades, highlights, presses, small icon changes.
  static const fast = Duration(milliseconds: 150);

  /// Sheets, panels, menus, page jumps.
  static const normal = Duration(milliseconds: 200);

  /// Large or full-screen moves.
  static const slow = Duration(milliseconds: 300);

  /// Something arriving or settling.
  static const enter = Curves.easeOutCubic;

  /// Something leaving.
  static const exit = Curves.easeInCubic;

  /// Something travelling from one place to another.
  static const move = Curves.easeInOutCubic;
}

/// Corner radii. Fully round shapes (pills, circles) use their own height.
abstract final class Radii {
  /// Chips, bars, small badges.
  static const double small = 4;

  /// Cards, menus, inputs, bubbles.
  static const double medium = 12;

  /// Sheets and the composer island.
  static const double large = 24;
}
