import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../util/insets.dart';

// Shared metrics and builders for the liquid glass chrome. The header block
// fuses the app bar and the channel tab strip, so both layers derive its
// height from the same formula and the chat list pads by the same amount.
const double kGlassAppBarHeight = 48.0;
const double kGlassTabStripHeight = 40.0;

/// Floating composer island: the field and the bottom buttons in one shell,
/// inset from the screen edges. The radius matches the opaque island's.
const double kComposerIslandMargin = 8.0;
const double kComposerIslandRadius = 16.0;

// Gap the list keeps above the in-flow composer when the glass pill is off.
const double kOpaqueComposerGap = 4.0;

// Gap the newest row keeps above a floating island at rest: the docked
// island's list gap plus its top margin, so both modes read the same.
const double kFloatingComposerGap = kOpaqueComposerGap + kComposerIslandMargin;

// Welcome overlay header height: status bar plus app bar row only. With no
// channels there is no tab strip, so the glass card holds the app bar alone
// and the welcome list pads by this shorter amount.
double glassWelcomeHeaderHeight(BuildContext context) =>
    statusBarHeight(context) + kGlassAppBarHeight;

// Island footprint the scrolling lists clear; the caller adds the safe area,
// so this is the island content plus its bottom margin.
double glassComposerOverlayHeight(double islandH) =>
    islandH + kComposerIslandMargin;

// How far the header glass bleeds past the screen on the top and sides.
// The rim follows the shape boundary, so pushing three boundaries
// off-screen leaves only the bottom rim visible across the chat.
const double kGlassEdgeBleed = 32.0;

// Glass stays off under high contrast; callers fall back to opaque chrome.
bool glassEnabled(BuildContext context, bool flag) =>
    flag && !MediaQuery.highContrastOf(context);

// Bottom clearance the scrolling lists keep above the composer pill.
// Provided by ChatBody around the body stack so every ChatView (main pages,
// welcome, panels) clears the pill without hand-threaded params. Zero when
// the pill is off, so the opaque theme renders exactly as before.
class GlassChromeScope extends InheritedWidget {
  const GlassChromeScope({
    super.key,
    required this.bottomClearance,
    this.listExtra = 0,
    this.glass = false,
    this.footerFor,
    this.footerHeight = 0,
    required super.child,
  });

  /// The island's clearance without its footer (the channel status line).
  final double bottomClearance;

  /// The footer height a channel's island shows. A chat page adds its own
  /// channel's to [bottomClearance], so it is placed for its island before a
  /// switch lands and only the island moves.
  final double Function(String channel)? footerFor;

  /// The selected channel's footer as measured, for lists tied to no channel
  /// (panels). Dependents are notified only when a footer comes or goes, not
  /// on every frame it grows.
  final double footerHeight;

  /// [bottomClearance] plus [channel]'s footer.
  double clearanceFor(String? channel) =>
      bottomClearance +
      (channel == null || channel.isEmpty ? 0 : footerFor?.call(channel) ?? 0);

  /// Whether the chrome is liquid glass. A floating island without glass
  /// still has a clearance, so styling reads this, not the clearance.
  final bool glass;

  /// Extra bottom padding the scrolling lists add on top of [bottomClearance]
  /// without moving the scroll-down button. Used for overlays that float above
  /// the composer, like the reply header.
  final double listExtra;

  static GlassChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassChromeScope>();

  @override
  bool updateShouldNotify(GlassChromeScope oldWidget) =>
      bottomClearance != oldWidget.bottomClearance ||
      listExtra != oldWidget.listExtra ||
      glass != oldWidget.glass ||
      footerFor != oldWidget.footerFor ||
      (footerHeight > 0.5) != (oldWidget.footerHeight > 0.5);
}

/// [base] plus the pill clearance, for plain lists in the chat body (panels,
/// mod view) so their last rows scroll clear of the composer like ChatView's.
EdgeInsets glassListPadding(
  BuildContext context, [
  EdgeInsets base = EdgeInsets.zero,
]) {
  final scope = GlassChromeScope.maybeOf(context);
  final extra =
      (scope?.bottomClearance ?? 0) +
      (scope?.footerHeight ?? 0) +
      (scope?.listExtra ?? 0);
  return base.copyWith(bottom: base.bottom + extra);
}

/// Glass drawn as a background layer behind [child].
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.shape,
    this.settings,
    this.quality = GlassQuality.premium,
    required this.child,
  });

  final LiquidShape shape;
  final LiquidGlassSettings? settings;

  /// Minimal is a plain frosted blur; it needs no own layer.
  final GlassQuality quality;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GlassContainer(
          quality: quality,
          settings: settings,
          useOwnLayer: quality != GlassQuality.minimal,
          shape: shape,
          child: const SizedBox.expand(),
        ),
      ),
      child,
    ],
  );
}

// Shared glass tint alpha (0x73 is about 45%): dark enough to hold contrast
// for light text, light enough to sit near the app's grey surfaces.
const int _kGlassTintAlpha = 0x73;

// Styled glass: thickness refracts rows scrolling underneath so light
// warps at the edges, fresnel plus specular draws the bright rim.
// Premium is the fidelity tier; both surfaces are fixed overlays (never
// list children), which is its sanctioned use.
/// Header glass, brightness-aware: a neutral tint whose alpha is the
/// opacity lever on the premium path. (standardOpacityMultiplier is
/// standard-path only and does nothing here, so it stays unset.)
LiquidGlassSettings _barSettings(bool dark, double visibility) =>
    LiquidGlassSettings(
      thickness: 34,
      // A frost cloud with a faint copy of the rows showing through keeps
      // the tabs readable over busy chat, while the rim still bends the
      // rows; the tint darkens what the frost lets through.
      blur: 1,
      frost: 14,
      frostOpacity: 0.92,
      refractiveIndex: 1.5,
      chromaticAberration: 0.02,
      lightIntensity: 0.6,
      fresnelStrength: 1.5,
      glassColor: dark
          ? const Color(_kGlassTintAlpha << 24)
          : const Color((_kGlassTintAlpha << 24) | 0xFFFFFF),
      visibility: visibility,
    );

/// The pill's material, shared by the small chrome tiles.
const kGlassPillSettings = LiquidGlassSettings(
  thickness: 26,
  // Frosted like the header so card and menu text reads over chat; the
  // dark tint holds contrast for light text in both themes' chat.
  blur: 1,
  frost: 14,
  frostOpacity: 0.92,
  glassColor: Color(_kGlassTintAlpha << 24),
  refractiveIndex: 1.5,
  chromaticAberration: 0.02,
  lightIntensity: 0.6,
  fresnelStrength: 1.5,
  // Neutral background passthrough: the 1.5 default boosts whatever shines
  // through the middle. The rim stays untouched (fresnel + specular as is).
  saturation: 1.0,
);

/// Full-bleed header fusing the app bar and the tab strip. The glass
/// extends past the screen on the top and sides (content is counter-padded
/// by the same amount) so only the bottom rim draws across the chat.
///
/// While [hidden] (fullscreen) it slides up and fades out, then goes
/// offstage so it captures no backdrop. The fade runs through the glass's
/// visibility and the content's own opacity, never an opacity above the
/// glass, which would keep it out of a [GlassBackdropGroup].
Widget glassHeaderBar({
  required bool hidden,
  required bool dark,
  required Widget child,
}) => IgnorePointer(
  ignoring: hidden,
  child: TweenAnimationBuilder<double>(
    tween: Tween(end: hidden ? 0 : 1),
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeInOut,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        kGlassEdgeBleed,
        kGlassEdgeBleed,
        kGlassEdgeBleed,
        0,
      ),
      child: child,
    ),
    builder: (context, shown, child) => Offstage(
      offstage: shown == 0,
      child: FractionalTranslation(
        translation: Offset(0, shown - 1),
        child: GlassSurface(
          settings: _barSettings(dark, shown),
          shape: const LiquidRoundedSuperellipse(borderRadius: 0),
          child: Opacity(opacity: shown, child: child),
        ),
      ),
    ),
  ),
);

// Floating composer island: field and buttons in one frosted rounded shell
// matching the opaque island's radius.
Widget glassIsland({required Widget child}) => GlassSurface(
  settings: kGlassPillSettings,
  shape: const LiquidRoundedSuperellipse(borderRadius: kComposerIslandRadius),
  child: child,
);

// Floating broadcast cards (pins, polls, predictions) over the chat.
Widget glassCard({required Widget child}) => GlassSurface(
  settings: kGlassPillSettings,
  shape: const LiquidRoundedSuperellipse(borderRadius: 12),
  child: child,
);

// Focus state for the composer island while any inner field holds focus.
// With a [surface], it paints the island's fill: a hair see-through at rest,
// opaque and faintly tinted toward primary when focused, so the state shows
// without a line. Without one (glass), it rings the island in primary over
// the shell's edge, in the shell's own [shape]. Neither shifts layout.
class ComposerFocusGlow extends StatelessWidget {
  const ComposerFocusGlow({
    super.key,
    required this.shape,
    this.surface,
    required this.child,
  });

  final OutlinedBorder shape;
  final Color? surface;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      // Observes the inner fields only; never a traversal stop itself.
      skipTraversal: true,
      // Reads focus on build rather than on change, so a field that arrives
      // already focused (the pill hand-off) lights the new shell at once.
      child: Builder(
        builder: (context) {
          final lit = Focus.of(context).hasFocus;
          final fill = surface;
          if (fill != null) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              decoration: ShapeDecoration(
                shape: shape,
                color: lit
                    ? Color.alphaBlend(primary.withValues(alpha: 0.06), fill)
                    : fill.withValues(alpha: 0.94),
              ),
              child: child,
            );
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            foregroundDecoration: ShapeDecoration(
              shape: shape.copyWith(
                side: BorderSide(
                  color: primary.withValues(alpha: lit ? 0.8 : 0),
                  width: 1.5,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
            ),
            child: child,
          );
        },
      ),
    );
  }
}
