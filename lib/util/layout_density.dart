import 'package:flutter/material.dart';

/// User choice for the chrome layout. [auto] resolves per device.
enum LayoutDensity { auto, compact, full }

/// Auto goes compact below this long side. The long side is the portrait
/// height whatever the rotation, so rotating never flips the layout. Small
/// phones top out near 720 (iPhone 8/SE: 667) and full-size ones start
/// near 812 (iPhone mini).
const double kCompactLongSideBelow = 740.0;

/// Resolves [density] against a screen of [size].
bool resolveCompact(LayoutDensity density, Size size) => switch (density) {
  LayoutDensity.compact => true,
  LayoutDensity.full => false,
  LayoutDensity.auto => size.longestSide < kCompactLongSideBelow,
};

/// Resolved compact flag from the app root, notifying only when it flips.
class CompactLayoutScope extends InheritedWidget {
  const CompactLayoutScope({
    super.key,
    required this.compact,
    required super.child,
  });

  final bool compact;

  @override
  bool updateShouldNotify(CompactLayoutScope oldWidget) =>
      compact != oldWidget.compact;
}

/// Whether the compact layout is on. False when no [CompactLayoutScope] is
/// mounted (tests), which keeps the full layout.
bool isCompactLayout(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<CompactLayoutScope>()?.compact ??
    false;

/// Installs [CompactLayoutScope] and, when compact, Material's compact
/// density for stock buttons, list tiles and menus. The tree shape is the
/// same either way, so a flip only rebuilds and never remounts the app.
Widget compactLayoutRoot(
  BuildContext context, {
  required LayoutDensity density,
  required Widget child,
}) {
  final compact = resolveCompact(density, MediaQuery.sizeOf(context));
  final theme = Theme.of(context);
  return CompactLayoutScope(
    compact: compact,
    child: Theme(
      data: compact
          ? theme.copyWith(visualDensity: VisualDensity.compact)
          : theme,
      child: child,
    ),
  );
}
