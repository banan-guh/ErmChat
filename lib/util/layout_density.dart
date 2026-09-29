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

/// Custom layout overrides. While [enabled] is false every behavior follows
/// the compact/full default; when true each switch forces its behavior in
/// both layouts.
class LayoutOverrides {
  const LayoutOverrides({
    this.enabled = false,
    this.mergeAppBar = true,
    this.foldPanelHeaders = true,
    this.tightComposer = true,
    this.sheetActionRow = false,
    this.compactDensity = true,
    this.tightChromeMargins = true,
  });

  /// Master switch: when false the individual switches are ignored.
  final bool enabled;

  /// Fold the app bar into the channel tab strip.
  final bool mergeAppBar;

  /// Fold panel titles into their tab row instead of stacking a title row.
  final bool foldPanelHeaders;

  /// Shorter composer with the emote and send buttons spilling into padding.
  final bool tightComposer;

  /// Icon-over-label action rows in the emote and user sheets. Off by
  /// default, and never on outside custom, so compact keeps the list.
  final bool sheetActionRow;

  /// Material's compact density for buttons, list tiles and menus.
  final bool compactDensity;

  /// Tighter chrome margins, e.g. the app bar action padding.
  final bool tightChromeMargins;

  /// Whether the sheets use the icon row. Only custom turns it on.
  bool get horizontalSheetActions => enabled && sheetActionRow;

  /// Resolves one behavior: the switch when custom is on, else the layout
  /// default ([compactDefault]).
  bool resolve(bool value, bool compactDefault) =>
      enabled ? value : compactDefault;

  @override
  bool operator ==(Object other) =>
      other is LayoutOverrides &&
      other.enabled == enabled &&
      other.mergeAppBar == mergeAppBar &&
      other.foldPanelHeaders == foldPanelHeaders &&
      other.tightComposer == tightComposer &&
      other.sheetActionRow == sheetActionRow &&
      other.compactDensity == compactDensity &&
      other.tightChromeMargins == tightChromeMargins;

  @override
  int get hashCode => Object.hash(
    enabled,
    mergeAppBar,
    foldPanelHeaders,
    tightComposer,
    sheetActionRow,
    compactDensity,
    tightChromeMargins,
  );
}

/// Resolved compact flag from the app root, notifying only when it flips.
class CompactLayoutScope extends InheritedWidget {
  const CompactLayoutScope({
    super.key,
    required this.compact,
    this.overrides = const LayoutOverrides(),
    required super.child,
  });

  final bool compact;

  /// Custom overrides, applied in both compact and full when enabled.
  final LayoutOverrides overrides;

  @override
  bool updateShouldNotify(CompactLayoutScope oldWidget) =>
      compact != oldWidget.compact || overrides != oldWidget.overrides;
}

/// Whether the compact layout is on. False when no [CompactLayoutScope] is
/// mounted (tests), which keeps the full layout.
bool isCompactLayout(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<CompactLayoutScope>()?.compact ??
    false;

/// The custom layout overrides, defaulting to all-auto without a scope.
LayoutOverrides layoutOverridesOf(BuildContext context) =>
    context
        .dependOnInheritedWidgetOfExactType<CompactLayoutScope>()
        ?.overrides ??
    const LayoutOverrides();

/// Resolves one override against the active compact flag.
bool resolveLayoutOverride(
  BuildContext context,
  bool Function(LayoutOverrides overrides) pick,
) {
  final overrides = layoutOverridesOf(context);
  return overrides.resolve(pick(overrides), isCompactLayout(context));
}

/// Installs [CompactLayoutScope] and, when compact, Material's compact
/// density for stock buttons, list tiles and menus. The tree shape is the
/// same either way, so a flip only rebuilds and never remounts the app.
Widget compactLayoutRoot(
  BuildContext context, {
  required LayoutDensity density,
  LayoutOverrides overrides = const LayoutOverrides(),
  required Widget child,
}) {
  final compact = resolveCompact(density, MediaQuery.sizeOf(context));
  final dense = overrides.resolve(overrides.compactDensity, compact);
  final theme = Theme.of(context);
  return CompactLayoutScope(
    compact: compact,
    overrides: overrides,
    child: Theme(
      data: dense
          ? theme.copyWith(visualDensity: VisualDensity.compact)
          : theme,
      child: child,
    ),
  );
}
